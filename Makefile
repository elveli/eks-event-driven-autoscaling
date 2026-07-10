# Convenience wrapper — every target is also runnable by hand (see README).
# Bring-up order: apply -> kubeconfig -> ci-var -> ci-run -> gitops -> url.
TF    := terraform -chdir=infra/environments/dev
STACK := infra/environments/dev/manage-aws-dev-stack.sh

.DEFAULT_GOAL := help
.PHONY: help plan apply destroy kubeconfig ci-var ci-run gitops argocd url submit stats queue dlq purge results watch pods nodes nodegroups scaling logs-worker logs-lambda irsa inventory

help:        ## this menu
	@grep -E '^[a-zA-Z-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN { FS = ":.*?## " } { printf "  \033[1m%-12s\033[0m %s\n", $$1, $$2 }'

# ---- lifecycle (via the wrapper script: init included, destroy confirmed) ----

plan:        ## terraform plan
	$(STACK) plan

apply:       ## provision VPC + EKS + Karpenter + platform + app resources (~20 min)
	$(STACK) apply

destroy:     ## the cost kill switch: tear it all down (state bucket survives)
	$(STACK) destroy

kubeconfig:  ## point kubectl at the cluster
	aws eks update-kubeconfig --region "$$($(TF) output -raw aws_region)" --name "$$($(TF) output -raw cluster_name)"

# ---- CI / GitOps bootstrap (once per bring-up) ----

ci-var:      ## give GitHub Actions the CI role ARN (repo variable AWS_ROLE_ARN)
	gh variable set AWS_ROLE_ARN --body "$$($(TF) output -raw gha_role_arn)"

ci-run:      ## build+scan+push images and pin their tags (the app workflow), then watch it
	gh workflow run app --ref main
	@sleep 5
	gh run watch "$$(gh run list --workflow=app --limit 1 --json databaseId --jq '.[0].databaseId')"

gitops:      ## hand the app over to Argo CD (apply the Application, pull the bump commit)
	git pull --rebase
	kubectl apply -f gitops/apps/eda-app.yaml

argocd:      ## Argo CD UI on https://localhost:8080 (prints the admin password)
	@echo "Argo CD: https://localhost:8080  user: admin  password: $$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
	kubectl -n argocd port-forward svc/argocd-server 8080:443

url:         ## the dashboard's ALB address (empty until the LB controller provisions it)
	@echo "http://$$(kubectl -n eda get ingress eda -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"

# ---- driving the demo ----

N   ?= 50
DUR ?= 15

submit:      ## enqueue a batch straight at the Lambda: make submit N=100 DUR=20
	@curl -sf -X POST "$$($(TF) output -raw lambda_function_url)api/submit" \
	  -H 'content-type: application/json' \
	  -d '{"count": $(N), "duration_s": $(DUR)}' && echo ""

stats:       ## queue depth as the dashboard sees it (via the Lambda)
	@curl -sf "$$($(TF) output -raw lambda_function_url)api/stats" && echo ""

watch:       ## the whole story every 2s: queue depth, worker pods, nodes
	@QUEUE_URL="$$($(TF) output -raw jobs_queue_url)"; \
	while true; do \
	  clear; date; \
	  echo ""; echo "── queue ──────────────────────────────────"; \
	  aws sqs get-queue-attributes --queue-url "$$QUEUE_URL" \
	    --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
	    --query 'Attributes.{queued:ApproximateNumberOfMessages,in_flight:ApproximateNumberOfMessagesNotVisible}' \
	    --output text | awk '{print "queued: " $$1 "   in-flight: " $$2}'; \
	  echo ""; echo "── worker pods ────────────────────────────"; \
	  kubectl get pods -n eda -l app=eda-worker --no-headers 2>/dev/null \
	    | awk '{print $$1 "  " $$3}' || echo "(none)"; \
	  echo ""; echo "── nodes ──────────────────────────────────"; \
	  kubectl get nodes -L karpenter.sh/nodepool --no-headers 2>/dev/null \
	    | awk '{print $$1 "  " $$2 "  " ($$6 == "" ? "system" : "karpenter")}'; \
	  sleep 2; \
	done

# ---- poking at state ----

queue:       ## raw SQS attributes of the jobs queue
	aws sqs get-queue-attributes --queue-url "$$($(TF) output -raw jobs_queue_url)" \
	  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible --output table

dlq:         ## anything in the dead-letter queue? (3 failed attempts land here)
	aws sqs get-queue-attributes --queue-url "$$($(TF) output -raw jobs_queue_url)-dlq" \
	  --attribute-names ApproximateNumberOfMessages --output table

purge:       ## drop every queued job (in-flight ones finish; pods then drain to 0)
	aws sqs purge-queue --queue-url "$$($(TF) output -raw jobs_queue_url)"

results:     ## worker output objects in S3, newest last + total count
	@aws s3 ls "s3://$$($(TF) output -raw bucket_name)/results/" | tail -20
	@echo "total: $$(aws s3 ls "s3://$$($(TF) output -raw bucket_name)/results/" | wc -l | tr -d ' ') results"

pods:        ## every pod in the cluster, with the node it runs on
	kubectl get pods -A -o wide

nodes:       ## nodes with their provenance (system node group vs Karpenter)
	kubectl get nodes -L karpenter.sh/nodepool,node.kubernetes.io/instance-type,karpenter.sh/capacity-type

nodegroups:  ## node capacity, both kinds: static system group + Karpenter pool/claims
	@REGION="$$($(TF) output -raw aws_region)"; CLUSTER="$$($(TF) output -raw cluster_name)"; \
	{ echo "NAME STATUS CAPACITY TYPES MIN DESIRED MAX"; \
	aws eks list-nodegroups --region "$$REGION" --cluster-name "$$CLUSTER" \
	    --query 'nodegroups[]' --output text | tr '\t' '\n' | while read -r ng; do \
	  aws eks describe-nodegroup --region "$$REGION" --cluster-name "$$CLUSTER" --nodegroup-name "$$ng" \
	    --query 'nodegroup.[nodegroupName,status,capacityType,join(`,`,instanceTypes),scalingConfig.minSize,scalingConfig.desiredSize,scalingConfig.maxSize]' \
	    --output text; \
	done; } | column -t
	@echo ""
	@echo "Karpenter NodePool (its cpu limit is the runaway-cost guardrail):"
	@kubectl get nodepool -o wide || echo "  (cluster unreachable)"
	@echo ""
	@echo "Karpenter NodeClaims (one per launched node; empty = workers at zero):"
	@kubectl get nodeclaims -o wide || echo "  (cluster unreachable)"

scaling:     ## both autoscalers side by side: KEDA ScaledObject + plain HPA
	kubectl get scaledobject,hpa,deploy -n eda

logs-worker: ## follow all worker logs (one JSON line per job event)
	kubectl logs -n eda -l app=eda-worker -f --tail=20 --max-log-requests=20

logs-lambda: ## follow the front-door Lambda's logs
	aws logs tail "/aws/lambda/$$($(TF) output -raw cluster_name)-front-door" --follow --since 15m

irsa:        ## service accounts annotated with IAM roles — the cluster's AWS-access wiring
	@{ echo "NAMESPACE SERVICEACCOUNT IAM_ROLE"; \
	kubectl get sa -A -o json | jq -r '.items[] \
	  | select(.metadata.annotations["eks.amazonaws.com/role-arn"]) \
	  | .metadata.namespace + " " + .metadata.name + " " \
	    + (.metadata.annotations["eks.amazonaws.com/role-arn"] | sub(".*role/"; ""))'; } | column -t

inventory:   ## every AWS resource carrying the Project=eda tag (should be empty after destroy)
	aws resourcegroupstaggingapi get-resources --region "$$($(TF) output -raw aws_region)" \
	  --tag-filters Key=Project,Values=eda \
	  --query 'ResourceTagMappingList[].ResourceARN' --output table
