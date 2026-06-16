.PHONY: build clean install test

BINARY  := bcm-node-ops-agent
VERSION := 2.0.0
GOFLAGS := -ldflags "-s -w -X main.version=$(VERSION)"

## build: Compile Go binary
build:
	@echo "Building $(BINARY) $(VERSION)..."
	CGO_ENABLED=0 go build $(GOFLAGS) -o $(BINARY) ./cmd/agent
	@echo "Built: ./$(BINARY)"

## clean: Remove build artifacts
clean:
	rm -f $(BINARY)

## test: Run unit tests
test:
	go test -v ./...

## install: Install to /opt/bcm-node-ops (requires sudo)
install: build
	@echo "Installing $(BINARY) to /opt/bcm-node-ops..."
	sudo mkdir -p /opt/bcm-node-ops/bin
	sudo cp $(BINARY) /opt/bcm-node-ops/bin/
	sudo cp -r config/ /opt/bcm-node-ops/config/
	sudo cp systemd/bcm-node-ops-agent-go.service /etc/systemd/system/
	sudo systemctl daemon-reload
	@echo "Installed. Enable with: sudo systemctl enable --now bcm-node-ops-agent-go"

## tidy: Download and tidy modules
tidy:
	go mod tidy

## fmt: Format code
fmt:
	gofmt -s -w .

## help: Show this help
help:
	@grep -E '^## ' Makefile | sed 's/## //' | column -t -s ':'
