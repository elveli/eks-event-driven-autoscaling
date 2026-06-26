# Phase 5 — Application AWS resources
# TODO:
#  - SQS queue eda-${env}-jobs (+ optional dead-letter queue)
#  - Optional SNS topic for completion events (SNS -> SQS fan-out if you want)
#  - S3 bucket for job payloads/results (block public access, SSE)
#  - Lambda (validator / presigned-URL issuer) + its execution role
#  - ECR repos: eda-web, eda-worker (scan-on-push ON, immutable tags)
#  - IRSA role for the WORKER service account: sqs:ReceiveMessage/DeleteMessage
#    on the jobs queue + s3:PutObject/GetObject on the bucket. No static keys.
