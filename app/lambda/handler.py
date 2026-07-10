"""Front-door Lambda: the write path into the pipeline.

Routes (invoked through the Function URL, usually via the dashboard's
nginx /api/ proxy — paths arrive unmodified):

  POST /api/submit   {"count": N, "duration_s": S, "s3_key": "..."}  ->
                     enqueue N jobs to SQS. s3_key is optional: when set
                     (from a prior /api/presign upload) every job in the
                     batch references that object and the worker hashes it.
  GET  /api/stats    -> approximate queue depth (visible + in flight).
  POST /api/presign  {"filename": "..."} -> presigned S3 PUT URL the browser
                     uploads a payload to directly (the Lambda never touches
                     the bytes — it only signs the URL).

Auth model: the Function URL is auth NONE by design (demo); validation here
is input hygiene, not authentication. Credentials come from the function's
execution role — no keys anywhere.
"""

import base64
import json
import os
import re
import uuid
from datetime import datetime, timezone

import boto3

QUEUE_URL = os.environ["QUEUE_URL"]
BUCKET = os.environ["BUCKET"]

# Bounds, not knobs: count caps a runaway batch, duration stays safely under
# the queue's 120s visibility timeout so an in-flight job is never redelivered
# mid-work (see app-resources var.job_visibility_timeout).
MAX_COUNT = 500
MAX_DURATION_S = 110
DEFAULT_DURATION_S = 15
PRESIGN_TTL_S = 900

sqs = boto3.client("sqs")
s3 = boto3.client("s3")


def _response(status: int, body: dict) -> dict:
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(body),
    }


def _bad_request(message: str) -> dict:
    return _response(400, {"error": message})


def _parse_body(event: dict) -> dict:
    raw = event.get("body") or "{}"
    if event.get("isBase64Encoded"):
        raw = base64.b64decode(raw).decode("utf-8")
    body = json.loads(raw)
    if not isinstance(body, dict):
        raise ValueError("body must be a JSON object")
    return body


def _submit(body: dict) -> dict:
    try:
        count = int(body.get("count", 1))
        duration_s = int(body.get("duration_s", DEFAULT_DURATION_S))
    except (TypeError, ValueError):
        return _bad_request("count and duration_s must be integers")

    if not 1 <= count <= MAX_COUNT:
        return _bad_request(f"count must be 1..{MAX_COUNT}")
    if not 1 <= duration_s <= MAX_DURATION_S:
        return _bad_request(f"duration_s must be 1..{MAX_DURATION_S}")

    s3_key = body.get("s3_key")
    if s3_key is not None:
        if not isinstance(s3_key, str) or not s3_key.startswith("uploads/") or len(s3_key) > 200:
            return _bad_request("s3_key must be an uploads/ key from /api/presign")

    batch_id = uuid.uuid4().hex[:8]
    submitted_at = datetime.now(timezone.utc).isoformat()
    messages = [
        {
            "Id": str(i),
            "MessageBody": json.dumps(
                {
                    "job_id": f"{batch_id}-{i:04d}",
                    "duration_s": duration_s,
                    "s3_key": s3_key,
                    "submitted_at": submitted_at,
                }
            ),
        }
        for i in range(count)
    ]

    # SendMessageBatch caps at 10 entries per call.
    for start in range(0, len(messages), 10):
        sqs.send_message_batch(QueueUrl=QUEUE_URL, Entries=messages[start : start + 10])

    return _response(200, {"enqueued": count, "batch_id": batch_id})


def _stats() -> dict:
    attrs = sqs.get_queue_attributes(
        QueueUrl=QUEUE_URL,
        AttributeNames=["ApproximateNumberOfMessages", "ApproximateNumberOfMessagesNotVisible"],
    )["Attributes"]
    return _response(
        200,
        {
            "queued": int(attrs["ApproximateNumberOfMessages"]),
            "in_flight": int(attrs["ApproximateNumberOfMessagesNotVisible"]),
        },
    )


def _presign(body: dict) -> dict:
    filename = body.get("filename")
    if not isinstance(filename, str) or not filename:
        return _bad_request("filename is required")
    safe_name = re.sub(r"[^A-Za-z0-9._-]", "_", filename)[-80:]
    key = f"uploads/{uuid.uuid4().hex[:8]}-{safe_name}"
    url = s3.generate_presigned_url(
        "put_object",
        Params={"Bucket": BUCKET, "Key": key},
        ExpiresIn=PRESIGN_TTL_S,
    )
    return _response(200, {"url": url, "key": key})


def handler(event, context):
    method = event.get("requestContext", {}).get("http", {}).get("method", "")
    path = event.get("rawPath", "")

    try:
        if method == "GET" and path == "/api/stats":
            return _stats()
        if method == "POST" and path == "/api/submit":
            return _submit(_parse_body(event))
        if method == "POST" and path == "/api/presign":
            return _presign(_parse_body(event))
    except (json.JSONDecodeError, ValueError) as exc:
        return _bad_request(f"invalid request body: {exc}")

    return _response(404, {"error": f"no route for {method} {path}"})
