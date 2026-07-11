# One image, two containers: the web Deployment runs this as-is (nginx serving
# the dashboard + proxying /api), and again as the stats sidecar with
# command: ["python3", "/opt/eda/stats_server.py"] (pod/node counts from the
# Kubernetes API). Sharing the image keeps CI to one build per component.
# 1.28 = current stable branch. The tag is floating, so the base layer can
# lag behind Alpine's own security patches between upstream rebuilds — `apk
# upgrade` pulls current patched packages at build time instead of whatever
# was baked in when this tag was last published.
#
# nginx itself is pinned exactly in the base image's /etc/apk/world (e.g.
# nginx=1.28.3-r1) because the nginx-module-{acme,geoip,image-filter,njs,
# xslt} dynamic modules require that exact build — `apk upgrade` respects
# the pin and leaves it alone even after the modules are gone. This image's
# nginx.conf template never loads any of them, so they're dropped (and their
# transitive libs — libgd, freetype, libxml2, ~30 packages), then nginx is
# upgraded past the pin explicitly with a relational constraint (not a bare
# version) so future rebuilds keep tracking Alpine's latest patched build
# instead of going stale again at whatever patch level is hardcoded today.
FROM nginx:1.28-alpine
RUN apk upgrade --no-cache \
    && apk del nginx-module-acme nginx-module-geoip nginx-module-image-filter nginx-module-njs nginx-module-xslt \
    && apk add --no-cache --upgrade 'nginx>1.28.3-r1' \
    && apk add --no-cache python3 \
    # The reinstalled nginx package doesn't ship /etc/nginx/conf.d as its own
    # directory entry (only files under it), so removing/upgrading the
    # package around it drops the directory entirely — recreate it
    # explicitly or the envsubst entrypoint has nowhere to render into.
    && mkdir -p /etc/nginx/conf.d /run/nginx
# Ours, not the base image's — see nginx.conf's own header comment for why.
COPY nginx.conf /etc/nginx/nginx.conf
# The entrypoint renders templates/*.template -> conf.d/*.conf via envsubst
# (LAMBDA_ORIGIN comes from the eda-app-config ConfigMap at runtime).
COPY templates/ /etc/nginx/templates/
COPY static/ /usr/share/nginx/html/
COPY stats_server.py /opt/eda/stats_server.py
