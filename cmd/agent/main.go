// Package main implements the BCM Node Operations Agent.
//
// This is the Go binary version of the agent. It subscribes to an SQS queue
// using true long-polling (WaitTimeSeconds=20), processes power operations
// via Redfish, and publishes results to a response SQS queue.
//
// Architecture:
//
//	SQS (requests) → Agent → Redfish BMC → SQS (responses)
//
// Features:
//   - True pub/sub via SQS long-poll (no sleep loops)
//   - Vendor-aware Redfish (DGX, iDRAC, iLO)
//   - 3-tier credential resolution (node → vendor → global)
//   - Structured JSON logging
//   - JSONL audit trail
//   - Graceful shutdown (SIGTERM/SIGINT)
//   - systemd Type=notify readiness
//
// Usage:
//
//	# Build
//	go build -o bcm-node-ops-agent ./cmd/agent
//
//	# Run with env vars
//	SQS_REQUEST_QUEUE_URL=... SQS_RESPONSE_QUEUE_URL=... ./bcm-node-ops-agent
//
//	# Or via systemd
//	sudo systemctl start bcm-node-ops-agent-go
package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/SrikantaDatta51/bcm-node-ops-agent/internal/config"
	"github.com/SrikantaDatta51/bcm-node-ops-agent/internal/ops"
	"github.com/SrikantaDatta51/bcm-node-ops-agent/internal/sqs"
)

func main() {
	// Structured JSON logger
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)

	logger.Info("bcm-node-ops-agent starting", "version", "2.0.0", "mode", "go-binary")

	// Load config from environment
	cfg := config.LoadConfig()
	if cfg.RequestQueueURL == "" || cfg.ResponseQueueURL == "" {
		logger.Error("SQS_REQUEST_QUEUE_URL and SQS_RESPONSE_QUEUE_URL are required")
		os.Exit(1)
	}

	// Load node inventory
	inventory, err := config.LoadInventory(cfg.NodeInventoryPath)
	if err != nil {
		logger.Error("failed to load inventory", "error", err, "path", cfg.NodeInventoryPath)
		os.Exit(1)
	}
	logger.Info("inventory loaded", "nodes", len(inventory.Nodes), "path", cfg.NodeInventoryPath)

	// Create context with cancellation for graceful shutdown
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Graceful shutdown on SIGTERM/SIGINT
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGTERM, syscall.SIGINT)

	// Initialize SQS consumer (long-poll subscriber)
	consumer, err := sqs.NewConsumer(ctx, cfg.RequestQueueURL, cfg.AWSRegion, cfg.MaxMessages, cfg.WaitTime, logger)
	if err != nil {
		logger.Error("failed to create SQS consumer", "error", err)
		os.Exit(1)
	}
	logger.Info("SQS consumer ready",
		"queue", cfg.RequestQueueURL,
		"wait_time_seconds", cfg.WaitTime,
		"max_messages", cfg.MaxMessages,
	)

	// Initialize SQS publisher (response queue)
	publisher, err := sqs.NewPublisher(ctx, cfg.ResponseQueueURL, cfg.AWSRegion, logger)
	if err != nil {
		logger.Error("failed to create SQS publisher", "error", err)
		os.Exit(1)
	}
	logger.Info("SQS publisher ready", "queue", cfg.ResponseQueueURL)

	// Initialize operation executor
	executor, err := ops.NewExecutor(cfg, inventory, publisher, logger)
	if err != nil {
		logger.Error("failed to create executor", "error", err)
		os.Exit(1)
	}
	defer executor.Close()

	// Signal readiness to systemd (Type=notify)
	if v := os.Getenv("NOTIFY_SOCKET"); v != "" {
		notifySystemd("READY=1")
	}

	logger.Info("agent ready — listening for SQS messages (long-poll)")

	// ── Main Loop ──────────────────────────────────────────────
	// True pub/sub: Receive() blocks until a message arrives or
	// WaitTimeSeconds elapses. No sleep loops.
	go func() {
		for {
			select {
			case <-ctx.Done():
				return
			default:
			}

			messages, err := consumer.Receive(ctx)
			if err != nil {
				if ctx.Err() != nil {
					return // context cancelled, shutting down
				}
				logger.Error("SQS receive error", "error", err)
				continue
			}

			for _, msg := range messages {
				// Check TTL
				if msg.IsExpired() {
					logger.Warn("message expired",
						"request_id", msg.Envelope.Payload.RequestID,
						"node", msg.Envelope.Payload.Node,
					)
					// Publish EXPIRED response
					expired := sqs.ResponsePayload{
						RequestID: msg.Envelope.Payload.RequestID,
						Node:      msg.Envelope.Payload.Node,
						Action:    msg.Envelope.Payload.Action,
						Status:    "EXPIRED",
						Phase:     "expired",
						Message:   "TTL exceeded — request discarded",
					}
					_ = publisher.PublishResult(ctx, msg.Envelope.CorrelationID, expired)
					_ = consumer.Delete(ctx, msg.ReceiptHandle)
					continue
				}

				// Execute the operation
				executor.Execute(ctx, msg)

				// Acknowledge the message
				if err := consumer.Delete(ctx, msg.ReceiptHandle); err != nil {
					logger.Error("failed to delete SQS message", "error", err, "sqs_id", msg.SQSMessageID)
				}
			}
		}
	}()

	// Wait for shutdown signal
	sig := <-sigChan
	logger.Info("shutdown signal received", "signal", sig.String())
	cancel()

	// Notify systemd we're stopping
	if v := os.Getenv("NOTIFY_SOCKET"); v != "" {
		notifySystemd("STOPPING=1")
	}

	logger.Info("agent stopped gracefully")
}

// notifySystemd sends a notification to the systemd socket
func notifySystemd(state string) {
	sockAddr := os.Getenv("NOTIFY_SOCKET")
	if sockAddr == "" {
		return
	}
	// Best-effort notification
	conn, err := syscall.Socket(syscall.AF_UNIX, syscall.SOCK_DGRAM, 0)
	if err != nil {
		return
	}
	defer syscall.Close(conn)
	addr := &syscall.SockaddrUnix{Name: sockAddr}
	_ = syscall.Sendto(conn, []byte(state), 0, addr)
	fmt.Fprintf(os.Stderr, "systemd notify: %s\n", state)
}
