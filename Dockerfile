# Self-hosted build (Coolify): the site is plain files, served by nginx on port 3000.
FROM nginx:1.31-alpine
COPY deploy/nginx.conf /etc/nginx/conf.d/default.conf
COPY . /usr/share/nginx/html/
RUN rm -rf /usr/share/nginx/html/deploy /usr/share/nginx/html/Dockerfile /usr/share/nginx/html/.dockerignore
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s CMD wget -q -O /dev/null http://127.0.0.1:3000/ || exit 1
