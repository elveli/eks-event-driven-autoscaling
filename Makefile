# Convenience wrapper — every target is also runnable by hand (see README).
# Bring-up order: apply -> kubeconfig -> ci-var -> ci-run -> gitops -> url.
TF    := terraform -chdir=infra/environments/dev
STACK := infra/environments/dev/manage-aws-dev-stack.sh

.DEFAULT_GOAL := help
.PHONY: help plan apply destroy kubeconfig ci-var ci-run gitops argocd url submit stats queue dlq purge results watch pods nodes nodegroups top scaling apps logs-worker logs-lambda logs-karpenter logs-keda irsa healthchecks inventory

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

# One-time bootstrap: creates the Argo CD Application resource (the CRD that
# tells Argo CD "watch gitops/manifests/ in this repo"). After this, Argo CD
# polls git directly and auto-syncs on every push — you don't re-run this
# for ordinary app changes, only if gitops/apps/eda-app.yaml itself changes.
gitops:      ## one-time: point Argo CD at gitops/manifests/ so it starts auto-syncing from git
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

top:         ## live CPU/memory usage — nodes and eda-namespace pods (needs metrics-server)
	kubectl top nodes
	@echo ""
	kubectl top pods -n eda

scaling:     ## both autoscalers side by side: KEDA ScaledObject + plain HPA
	kubectl get scaledobject,hpa,deploy -n eda

apps:        ## Argo CD Applications — sync/health status at a glance
	kubectl get applications -n argocd

logs-worker: ## follow all worker logs (one JSON line per job event)
	kubectl logs -n eda -l app=eda-worker -f --tail=20 --max-log-requests=20

logs-lambda: ## follow the front-door Lambda's logs
	aws logs tail "/aws/lambda/$$($(TF) output -raw cluster_name)-front-door" --follow --since 15m

logs-karpenter: ## follow Karpenter's logs (node provisioning/consolidation decisions)
	kubectl logs -n karpenter -l app.kubernetes.io/instance=karpenter -f --tail=20 --max-log-requests=10 --prefix

logs-keda:   ## follow KEDA's logs (operator + admission webhook + metrics apiserver, prefixed)
	kubectl logs -n keda -l app.kubernetes.io/instance=keda -f --tail=20 --max-log-requests=10 --prefix

irsa:        ## service accounts annotated with IAM roles — the cluster's AWS-access wiring
	@{ echo "NAMESPACE SERVICEACCOUNT IAM_ROLE"; \
	kubectl get sa -A -o json | jq -r '.items[] \
	  | select(.metadata.annotations["eks.amazonaws.com/role-arn"]) \
	  | .metadata.namespace + " " + .metadata.name + " " \
	    + (.metadata.annotations["eks.amazonaws.com/role-arn"] | sub(".*role/"; ""))'; } | column -t

# ---- health gate ----
# Unlike the "poking at state" targets above (which just print what's there),
# this is pass/fail: it checks Argo CD's own sync/health verdict, compares
# each Deployment's spec.replicas (whatever the HPA/KEDA last decided, so a
# scaled-to-zero worker is correctly "healthy") against readyReplicas, and
# walks the ALB's actual target group instead of trusting the Ingress alone.
# Exits 1 if anything's off — safe to use as a bring-up gate in a script.
healthchecks: ## pass/fail gate: Argo CD sync/health, Deployment readiness, ALB target health
	@FAIL=0; \
	echo "── Argo CD Application (eda) ───────────────"; \
	SYNC="$$(kubectl -n argocd get application eda -o jsonpath='{.status.sync.status}' 2>/dev/null)"; \
	HEALTH="$$(kubectl -n argocd get application eda -o jsonpath='{.status.health.status}' 2>/dev/null)"; \
	if [ "$$SYNC" = "Synced" ] && [ "$$HEALTH" = "Healthy" ]; then \
	  echo "  OK    sync=$$SYNC health=$$HEALTH"; \
	else \
	  echo "  FAIL  sync=$${SYNC:-unreachable} health=$${HEALTH:-unreachable}"; FAIL=1; \
	fi; \
	echo ""; echo "── Deployments (eda namespace) ─────────────"; \
	for D in eda-web eda-worker; do \
	  DESIRED="$$(kubectl -n eda get deploy $$D -o jsonpath='{.spec.replicas}' 2>/dev/null)"; \
	  READY="$$(kubectl -n eda get deploy $$D -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"; \
	  READY="$${READY:-0}"; \
	  if [ -z "$$DESIRED" ]; then \
	    echo "  FAIL  $$D unreachable"; FAIL=1; \
	  elif [ "$$READY" = "$$DESIRED" ]; then \
	    echo "  OK    $$D ready=$$READY/$$DESIRED"; \
	  else \
	    echo "  FAIL  $$D ready=$$READY/$$DESIRED"; FAIL=1; \
	  fi; \
	done; \
	echo ""; echo "── ALB target health ────────────────────────"; \
	REGION="$$($(TF) output -raw aws_region 2>/dev/null)"; REGION="$${REGION:-us-east-1}"; \
	HOST="$$(kubectl -n eda get ingress eda -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)"; \
	if [ -z "$$HOST" ]; then \
	  echo "  FAIL  ingress has no ALB hostname yet"; FAIL=1; \
	else \
	  ALB_ARN="$$(aws elbv2 describe-load-balancers --region "$$REGION" \
	    --query "LoadBalancers[?DNSName=='$$HOST'].LoadBalancerArn" --output text)"; \
	  if [ -z "$$ALB_ARN" ]; then \
	    echo "  FAIL  no ALB found for $$HOST"; FAIL=1; \
	  else \
	    TG_ARN="$$(aws elbv2 describe-target-groups --region "$$REGION" --load-balancer-arn "$$ALB_ARN" \
	      --query 'TargetGroups[0].TargetGroupArn' --output text)"; \
	    if [ -z "$$TG_ARN" ] || [ "$$TG_ARN" = "None" ]; then \
	      echo "  FAIL  no target group behind $$HOST"; FAIL=1; \
	    else \
	      HEALTH_OUT="$$(aws elbv2 describe-target-health --region "$$REGION" --target-group-arn "$$TG_ARN" \
	        --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason]' --output text)"; \
	      if [ -z "$$HEALTH_OUT" ]; then \
	        echo "  FAIL  no registered targets behind $$HOST"; FAIL=1; \
	      elif echo "$$HEALTH_OUT" | awk '{print $$2}' | grep -qv '^healthy$$'; then \
	        echo "  FAIL  unhealthy target(s) behind $$HOST:"; \
	        echo "$$HEALTH_OUT" | sed 's/^/    /'; \
	        FAIL=1; \
	      else \
	        echo "  OK    all targets healthy ($$HOST)"; \
	      fi; \
	    fi; \
	  fi; \
	fi; \
	echo ""; \
	if [ "$$FAIL" = "1" ]; then echo "RESULT: unhealthy"; exit 1; else echo "RESULT: healthy"; fi

# Region falls back to the variables.tf default because the primary use of
# inventory is AFTER destroy — when the state has no outputs left to read
# (and `terraform output` then exits 0 with EMPTY stdout, so guard the value).
inventory:   ## leak check: Project=eda resources (cross-verified live) + controller-created orphans (after destroy: only the bootstrap pair)
	@infra/environments/dev/inventory.sh
	@echo ""
	@REGION="$$($(TF) output -raw aws_region 2>/dev/null)"; REGION="$${REGION:-us-east-1}"; \
	echo "── controller-created (NO Project tag — orphaned if the cluster dies first) ──"; \
	echo "Karpenter EC2 instances:"; \
	aws ec2 describe-instances --region "$$REGION" \
	  --filters "Name=tag-key,Values=karpenter.sh/nodeclaim" \
	            "Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped" \
	  --query 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name]' --output text \
	  | column -t | sed 's/^/  /' | grep . || echo "  none"; \
	echo "LB-controller ALBs (k8s- name prefix):"; \
	aws elbv2 describe-load-balancers --region "$$REGION" \
	  --query 'LoadBalancers[?starts_with(LoadBalancerName, `k8s-`)].[LoadBalancerName,DNSName]' --output text \
	  | column -t | sed 's/^/  /' | grep . || echo "  none"
