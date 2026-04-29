FROM ghcr.io/ccarpinteri/pia-wg-config:latest AS pia

FROM alpine:3.20

RUN apk add --no-cache ca-certificates docker-cli docker-cli-compose curl

WORKDIR /app

COPY --from=pia /usr/local/bin/pia-wg-config /usr/local/bin/pia-wg-config
RUN chmod +x /usr/local/bin/pia-wg-config

COPY entrypoint.sh /app/entrypoint.sh
COPY refresh-loop.sh /app/refresh-loop.sh

RUN chmod +x /app/entrypoint.sh /app/refresh-loop.sh

ENTRYPOINT ["/app/entrypoint.sh"]
