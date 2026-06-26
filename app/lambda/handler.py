"""Front-door Lambda: validates a submit request and either enqueues jobs to
SQS or returns S3 presigned upload URLs. Also serves /api/stats for the
dashboard (queue depth via SQS attributes).

TODO:
  - route on path/method (submit vs stats)
  - validate payload
  - enqueue to SQS (QUEUE_URL) and/or presign S3 PUT (BUCKET)
  - return CORS-friendly JSON
"""

def handler(event, context):
    raise NotImplementedError("Scaffold — implement submit/stats routes.")
