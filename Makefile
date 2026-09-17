VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
BUILD_TIME ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
LDFLAGS := -s -w -X main.version=$(VERSION) -X main.buildTime=$(BUILD_TIME) -X main.commit=$(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)

NODE_BIN := tx-node
CTL_BIN := txctl
LEGACY_NODE_BIN := xboard-node
LEGACY_CTL_BIN := xbctl

.PHONY: build clean test docker install build-linux build-linux-arm64 build-all

# Build for current platform. TX-Node names are canonical; legacy aliases stay
# available during the compatibility window.
build:
	go build -ldflags "$(LDFLAGS)" -tags "with_quic with_utls with_wireguard with_clash_api" -o $(NODE_BIN) ./cmd/xboard-node
	go build -ldflags "$(LDFLAGS)" -o $(CTL_BIN) ./cmd/xbctl
	ln -sf $(NODE_BIN) $(LEGACY_NODE_BIN)
	ln -sf $(CTL_BIN) $(LEGACY_CTL_BIN)

# Build for Linux amd64
build-linux:
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags "$(LDFLAGS)" -tags "with_quic with_utls with_wireguard with_acme with_clash_api" -o tx-node-linux-amd64 ./cmd/xboard-node
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags "$(LDFLAGS)" -o txctl-linux-amd64 ./cmd/xbctl
	cp tx-node-linux-amd64 xboard-node-linux-amd64
	cp txctl-linux-amd64 xbctl-linux-amd64

# Build for Linux arm64
build-linux-arm64:
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags "$(LDFLAGS)" -tags "with_quic with_utls with_wireguard with_acme with_clash_api" -o tx-node-linux-arm64 ./cmd/xboard-node
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags "$(LDFLAGS)" -o txctl-linux-arm64 ./cmd/xbctl
	cp tx-node-linux-arm64 xboard-node-linux-arm64
	cp txctl-linux-arm64 xbctl-linux-arm64

# Build all platforms
build-all: build-linux build-linux-arm64

# Run tests
test:
	go test -v -race -count=1 ./internal/...

# Clean build artifacts
clean:
	rm -f tx-node txctl xboard-node xbctl tx-node-linux-* txctl-linux-* xboard-node-linux-* xbctl-linux-*

# Build Docker image
docker:
	docker build -t tx-node:$(VERSION) -t tx-node:latest .

# Install canonical TX-Node binaries. The old command names remain as symlinks
# so scripts written for Xboard-Node continue to work during migration.
install: build
	sudo cp $(NODE_BIN) /usr/local/bin/$(NODE_BIN)
	sudo cp $(CTL_BIN) /usr/local/bin/$(CTL_BIN)
	sudo ln -sf /usr/local/bin/$(NODE_BIN) /usr/local/bin/$(LEGACY_NODE_BIN)
	sudo ln -sf /usr/local/bin/$(CTL_BIN) /usr/local/bin/$(LEGACY_CTL_BIN)
	sudo mkdir -p /etc/txnode
	@if [ ! -f /etc/txnode/config.yml ]; then \
		sudo cp config.yml.example /etc/txnode/config.yml; \
		echo "Config copied to /etc/txnode/config.yml - please edit it"; \
	fi
