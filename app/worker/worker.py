"""EDA worker: drains the jobs queue. KEDA scales this process 0..N on queue
depth; each replica long-polls SQS, processes one message at a time, writes a
result object to S3, and deletes the message.

Credentials come from IRSA at runtime (the pod's ServiceAccount is annotated
with the worker IAM role) — no access keys are read from anywhere.

Delivery semantics are standard SQS at-least-once:
  - success  -> delete the message
  - failure  -> no delete; the message reappears after the visibility timeout
                and lands in the DLQ after 3 attempts (redrive policy)
  - SIGTERM  (KEDA scaling in / node draining) -> finish the current job,
                then exit; anything not yet received stays queued
"""

import hashlib
import json
import os
import signal
import socket
import time
from datetime import datetime, timezone

import boto3

QUEUE_URL = os.environ["QUEUE_URL"]
BUCKET = os.environ["BUCKET"]
WORKER_ID = os.environ.get("HOSTNAME", socket.gethostname())

# Must stay under the queue's 120s visibility timeout (the Lambda enforces
# the same bound on submit; this is defense in depth against crafted messages).
MAX_DURATION_S = 110

sqs = boto3.client("sqs")
s3 = boto3.client("s3")

shutting_down = False


def _log(event: str, **fields) -> None:
    print(json.dumps({"event": event, "worker": WORKER_ID, **fields}), flush=True)


def _request_shutdown(signum, frame) -> None:
    global shutting_down
    shutting_down = True
    _log("shutdown_requested", signal=signum)


def _simulate_work(duration_s: int, seed: bytes) -> str:
    """Burn a little CPU for duration_s seconds (~20% duty cycle) and return
    the running hash. Mostly-sleep keeps N workers per node honest: pods pack
    by their CPU *requests*, which is what drives Karpenter, not utilization.
    """
    digest = hashlib.sha256(seed).digest()
    deadline = time.monotonic() + duration_s
    while time.monotonic() < deadline:
        burn_until = min(time.monotonic() + 0.2, deadline)
        while time.monotonic() < burn_until:
            digest = hashlib.sha256(digest).digest()
        time.sleep(min(0.8, max(0.0, deadline - time.monotonic())))
    return digest.hex()


def _process(message: dict) -> None:
    received_at = datetime.now(timezone.utc).isoformat()
    job = json.loads(message["Body"])
    job_id = job["job_id"]
    duration_s = min(int(job.get("duration_s", 1)), MAX_DURATION_S)
    _log("job_started", job_id=job_id, duration_s=duration_s)

    # Optional payload: a batch submitted with an uploaded file references it
    # by key; hash it so the result provably depends on the payload bytes.
    payload_sha256 = None
    payload_bytes = None
    if job.get("s3_key"):
        body = s3.get_object(Bucket=BUCKET, Key=job["s3_key"])["Body"].read()
        payload_sha256 = hashlib.sha256(body).hexdigest()
        payload_bytes = len(body)

    work_digest = _simulate_work(duration_s, job_id.encode())

    result = {
        "job_id": job_id,
        "worker": WORKER_ID,
        "submitted_at": job.get("submitted_at"),
        "received_at": received_at,
        "finished_at": datetime.now(timezone.utc).isoformat(),
        "duration_s": duration_s,
        "work_digest": work_digest,
        "payload_sha256": payload_sha256,
        "payload_bytes": payload_bytes,
    }
    s3.put_object(
        Bucket=BUCKET,
        Key=f"results/{job_id}.json",
        Body=json.dumps(result).encode(),
        ContentType="application/json",
    )
    _log("job_finished", job_id=job_id)


def main() -> None:
    signal.signal(signal.SIGTERM, _request_shutdown)
    signal.signal(signal.SIGINT, _request_shutdown)
    _log("worker_started")

    while not shutting_down:
        # One message at a time keeps the KEDA math legible: queue depth /
        # queueLength ≈ desired replicas, each visibly chewing one job.
        response = sqs.receive_message(
            QueueUrl=QUEUE_URL,
            MaxNumberOfMessages=1,
            WaitTimeSeconds=20,
        )
        for message in response.get("Messages", []):
            try:
                _process(message)
            except Exception as exc:  # noqa: BLE001 — keep the loop alive
                # No delete: the message returns after the visibility timeout
                # and hits the DLQ on the third failure.
                _log("job_failed", error=repr(exc))
                continue
            sqs.delete_message(QueueUrl=QUEUE_URL, ReceiptHandle=message["ReceiptHandle"])

    _log("worker_stopped")


if __name__ == "__main__":
    main()
