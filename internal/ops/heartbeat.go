// Package ops provides a heartbeat publisher for the fleet agent.
//
// The heartbeat goroutine publishes agent status to the SQS response queue
// every HeartbeatInterval seconds. The fleet API consumes these heartbeats
// to track agent liveness and version.
package ops

import (
	"context"
	"log/slog"
	"os"
	"runtime"
	"time"

	"github.com/SrikantaDatta51/bcm-node-ops-agent/internal/config"
	"github.com/SrikantaDatta51/bcm-node-ops-agent/internal/sqs"
)

const defaultHeartbeatInterval = 60 * time.Second

// Heartbeat publishes periodic agent status messages.
type Heartbeat struct {
	publisher *sqs.Publisher
	cfg       *config.Config
	inventory *config.Inventory
	interval  time.Duration
	logger    *slog.Logger
	startTime time.Time
}

// NewHeartbeat creates a new heartbeat publisher.
func NewHeartbeat(cfg *config.Config, inv *config.Inventory, pub *sqs.Publisher, logger *slog.Logger) *Heartbeat {
	interval := defaultHeartbeatInterval
	if cfg.HeartbeatIntervalSec > 0 {
		interval = time.Duration(cfg.HeartbeatIntervalSec) * time.Second
	}
	return &Heartbeat{
		publisher: pub,
		cfg:       cfg,
		inventory: inv,
		interval:  interval,
		logger:    logger,
		startTime: time.Now(),
	}
}

// Run starts the heartbeat loop. Blocks until ctx is cancelled.
func (h *Heartbeat) Run(ctx context.Context) {
	h.logger.Info("heartbeat started", "interval_seconds", h.interval.Seconds())

	// Send initial heartbeat immediately
	h.send(ctx)

	ticker := time.NewTicker(h.interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			h.logger.Info("heartbeat stopped")
			return
		case <-ticker.C:
			h.send(ctx)
		}
	}
}

func (h *Heartbeat) send(ctx context.Context) {
	hostname, _ := os.Hostname()
	uptime := int(time.Since(h.startTime).Seconds())

	payload := sqs.ResponsePayload{
		RequestID: "heartbeat",
		Node:      hostname,
		Action:    "heartbeat",
		Status:    "ONLINE",
		Phase:     "running",
		Message:   "Agent heartbeat",
		Details: map[string]interface{}{
			"agent_version": "2.0.0",
			"mode":          "go-binary",
			"hostname":      hostname,
			"node_count":    len(h.inventory.Nodes),
			"uptime_seconds": uptime,
			"go_version":    runtime.Version(),
			"os_arch":       runtime.GOOS + "/" + runtime.GOARCH,
		},
	}

	if err := h.publisher.PublishResult(ctx, "heartbeat", payload); err != nil {
		h.logger.Error("heartbeat publish failed", "error", err)
	} else {
		h.logger.Debug("heartbeat sent", "uptime_seconds", uptime, "node_count", len(h.inventory.Nodes))
	}
}
