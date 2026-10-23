FROM nginx:1.27-alpine

RUN addgroup -g 1001 -S appgroup && \
    adduser -u 1001 -S appuser -G appgroup && \
    mkdir -p /var/cache/nginx/client_temp \
             /var/cache/nginx/proxy_temp \
             /var/cache/nginx/fastcgi_temp \
             /var/cache/nginx/uwsgi_temp \
             /var/cache/nginx/scgi_temp && \
    chown -R appuser:appgroup /var/cache/nginx /var/log/nginx /etc/nginx/conf.d && \
    touch /var/run/nginx.pid && chown appuser:appgroup /var/run/nginx.pid

COPY nginx.conf /etc/nginx/nginx.conf
COPY homepage.html /usr/share/nginx/html/homepage.html

RUN chown appuser:appgroup /etc/nginx/nginx.conf /usr/share/nginx/html/homepage.html && \
    chmod 644 /etc/nginx/nginx.conf /usr/share/nginx/html/homepage.html

USER appuser

EXPOSE 8080

# O Traefik so roteia o container depois de "healthy": no start period o teste
# roda a cada 1s, entao o site volta ~1s apos o deploy (e nao apos o 1o interval).
HEALTHCHECK --interval=30s --timeout=3s --start-period=30s --start-interval=1s --retries=3 \
  CMD wget -qO /dev/null http://127.0.0.1:8080/ || exit 1