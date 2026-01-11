FROM golang:1.23-alpine AS pia

ARG PIA_WG_CONFIG_REF=main

RUN apk add --no-cache git

WORKDIR /src

RUN git clone https://github.com/Ephemeral-Dust/pia-wg-config.git . \
  && git checkout "$PIA_WG_CONFIG_REF" \
  && go build -o pia-wg-config . \
  && cp /src/pia-wg-config /tmp/pia-wg-config

FROM alpine:3.20

RUN apk add --no-cache ca-certificates docker-cli

WORKDIR /app

COPY --from=pia /tmp/pia-wg-config /usr/local/bin/pia-wg-config
RUN chmod +x /usr/local/bin/pia-wg-config

COPY entrypoint.sh /app/entrypoint.sh
COPY refresh-loop.sh /app/refresh-loop.sh

RUN chmod +x /app/entrypoint.sh /app/refresh-loop.sh

ENTRYPOINT ["/app/entrypoint.sh"]
