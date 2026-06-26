# Job processor. Long-polls SQS, processes a job, writes result to S3,
# deletes the message. Scaled 0..N by KEDA on SQS queue depth.
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY worker.py .
CMD ["python", "worker.py"]
