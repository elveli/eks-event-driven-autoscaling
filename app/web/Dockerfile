# nginx serving the static dashboard + reverse-proxying /api to the Lambda URL.
FROM nginx:1.27-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY static/ /usr/share/nginx/html/
# TODO: add static/ (index.html dashboard that polls /api/stats and renders
#       queue depth, pod count, node count).
