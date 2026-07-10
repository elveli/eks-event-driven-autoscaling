"""Cluster-stats sidecar: the dashboard's /api/cluster backend.

The browser can't talk to the Kubernetes API (no credentials), and the
front-door Lambda deliberately has no cluster access — so pod/node counts
come from this tiny stdlib-only HTTP server running next to nginx in the
web pod. It authenticates with the pod's own ServiceAccount token; the
eda-web RBAC in gitops/manifests/rbac.yaml grants exactly list/get on pods
(namespace) and nodes (cluster) and nothing else.

GET /         -> {"worker_pods": {"running", "pending"},
                  "nodes": {"total", "karpenter"}}
GET /healthz  -> ok (no Kubernetes calls; the container's readiness probe)
"""

import json
import ssl
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
API = "https://kubernetes.default.svc"

with open(f"{SA_DIR}/namespace") as fh:
    NAMESPACE = fh.read().strip()

# The CA is stable for the pod's lifetime; the token is not (bound tokens
# rotate), so the token is re-read per request below.
SSL_CTX = ssl.create_default_context(cafile=f"{SA_DIR}/ca.crt")


def k8s_get(path: str) -> dict:
    with open(f"{SA_DIR}/token") as fh:
        token = fh.read().strip()
    req = urllib.request.Request(API + path, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=3, context=SSL_CTX) as resp:
        return json.load(resp)


def cluster_stats() -> dict:
    selector = urllib.parse.quote("app=eda-worker")
    pods = k8s_get(f"/api/v1/namespaces/{NAMESPACE}/pods?labelSelector={selector}")["items"]
    running = sum(
        1
        for p in pods
        if p["status"].get("phase") == "Running" and not p["metadata"].get("deletionTimestamp")
    )
    pending = sum(1 for p in pods if p["status"].get("phase") == "Pending")

    nodes = k8s_get("/api/v1/nodes")["items"]
    karpenter = sum(
        1 for n in nodes if "karpenter.sh/nodepool" in n["metadata"].get("labels", {})
    )
    return {
        "worker_pods": {"running": running, "pending": pending},
        "nodes": {"total": len(nodes), "karpenter": karpenter},
    }


class Handler(BaseHTTPRequestHandler):
    def _send(self, status: int, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802 — BaseHTTPRequestHandler API
        if self.path == "/healthz":
            self._send(200, b"ok", "text/plain")
            return
        if self.path in ("/", "/api/cluster"):
            try:
                body = json.dumps(cluster_stats()).encode()
                self._send(200, body, "application/json")
            except Exception as exc:  # noqa: BLE001 — surface, don't crash
                self._send(502, json.dumps({"error": repr(exc)}).encode(), "application/json")
            return
        self._send(404, b"not found", "text/plain")

    def log_message(self, *args) -> None:
        pass  # 0.5 req/s of polling would drown real logs


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
