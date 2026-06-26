"""BurstLab worker.

Credentials come from IRSA at runtime (the pod's ServiceAccount is annotated
with the worker IAM role) — do NOT read access keys from env.

TODO:
  - long-poll SQS (QUEUE_URL from env)
  - for each message: do the work (real file processing, or synthetic
    CPU/sleep load — see CLAUDE.md), write result to S3 (BUCKET from env)
  - delete the message on success; let it return to the queue on failure
  - optional: publish a completion event to SNS
"""

def main() -> None:
    raise NotImplementedError("Scaffold — implement the SQS poll loop.")


if __name__ == "__main__":
    main()
