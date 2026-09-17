# Build stage
FROM golang:1.26-alpine AS builder

RUN apk add --no-cache git

WORKDIR /build

COPY go.mod go.sum ./
RUN go mod download

COPY . .

RUN CGO_ENABLED=0 go build -ldflags "-s -w \
    -X main.version=$(git describe --tags --always --dirty 2>/dev/null || echo dev) \
    -X main.buildTime=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    -tags "with_quic with_utls with_wireguard with_clash_api" \
    -o tx-node ./cmd/xboard-node

# Runtime stage — sing-box & xray-core are embedded as Go libraries
FROM alpine:3.20

RUN apk add --no-cache ca-certificates tzdata

COPY --from=builder /build/tx-node /usr/local/bin/tx-node

# Keep the legacy executable name and in-container config path as compatibility
# aliases. New deployments should use the tx-node command and host-side
# /etc/txnode layout managed by deploy.sh.
RUN ln -s /usr/local/bin/tx-node /usr/local/bin/xboard-node \
    && mkdir -p /etc/xboard-node

WORKDIR /etc/xboard-node

# Config can be provided via file mount OR environment variables.
# Env var mode (no config file needed):
#   docker run -d --network=host \
#     -e apiHost=https://panel.example.com \
#     -e apiKey=YOUR_TOKEN \
#     -e nodeID=1 \
#     ghcr.io/paimoncai/tx-node:latest
#
# Supported env vars:
#   apiHost  / API_HOST    → panel URL
#   apiKey   / API_KEY     → server token
#   nodeID   / NODE_ID     → node ID
#   nodeType / NODE_TYPE   → node type (optional)
#   kernel   / KERNEL_TYPE → singbox (default) or xray
#   domain   / DOMAIN      → TLS domain (enables auto_tls)
#   certFile / CERT_FILE   → TLS cert path
#   keyFile  / KEY_FILE    → TLS key path
#   logLevel / LOG_LEVEL   → log level

ENTRYPOINT ["tx-node"]
CMD ["-c", "/etc/xboard-node/config.yml"]
