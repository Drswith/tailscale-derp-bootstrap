ARG GO_VERSION=1.26.8
ARG TAILSCALE_VERSION=1.102.4
ARG CERTBOT_VERSION=5.8.0

FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-bookworm AS derper-build
ARG TAILSCALE_VERSION
ARG TARGETARCH
ARG GOPROXY=https://proxy.golang.org,direct
ENV GOPROXY=$GOPROXY GOSUMDB=sum.golang.org GOTOOLCHAIN=local
RUN CGO_ENABLED=0 GOOS=linux GOARCH=$TARGETARCH \
      go install tailscale.com/cmd/derper@v${TAILSCALE_VERSION} && \
    if [ -f /go/bin/derper ]; then binary=/go/bin/derper; \
      else binary=/go/bin/linux_${TARGETARCH}/derper; fi && \
    install -D "$binary" /out/derper

FROM tailscale/tailscale:v${TAILSCALE_VERSION} AS tailscale-binaries

FROM python:3.12-slim-bookworm
ARG CERTBOT_VERSION
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl jq openssl iproute2 procps && \
    python -m pip install --no-cache-dir "certbot==${CERTBOT_VERSION}" && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

COPY --from=tailscale-binaries /usr/local/bin/tailscale /usr/local/bin/tailscale
COPY --from=tailscale-binaries /usr/local/bin/tailscaled /usr/local/bin/tailscaled
COPY --from=derper-build /out/derper /usr/local/bin/derper
COPY lib/common.sh /usr/local/libexec/derp-bootstrap/common.sh
COPY docker/entrypoint.sh /usr/local/bin/derp-container-entrypoint
COPY docker/healthcheck.sh /usr/local/bin/derp-container-healthcheck

ENTRYPOINT ["/usr/local/bin/derp-container-entrypoint"]
