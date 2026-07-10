# One image, two containers: the web Deployment runs this as-is (nginx serving
# the dashboard + proxying /api), and again as the stats sidecar with
# command: ["python3", "/opt/eda/stats_server.py"] (pod/node counts from the
# Kubernetes API). Sharing the image keeps CI to one build per component.
# 1.28 = current stable branch; older pins (1.27) carry known HIGH/CRITICAL
# CVEs that would trip the Trivy gate in CI.
FROM nginx:1.28-alpine
RUN apk add --no-cache python3
# The entrypoint renders templates/*.template -> conf.d/*.conf via envsubst
# (LAMBDA_ORIGIN comes from the eda-app-config ConfigMap at runtime).
COPY templates/ /etc/nginx/templates/
COPY static/ /usr/share/nginx/html/
COPY stats_server.py /opt/eda/stats_server.py
