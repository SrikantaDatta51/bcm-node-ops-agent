package ops

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"time"

	"github.com/SrikantaDatta51/bcm-node-ops-agent/internal/config"
	"github.com/SrikantaDatta51/bcm-node-ops-agent/internal/redfish"
	"github.com/SrikantaDatta51/bcm-node-ops-agent/internal/sqs"
)

// Executor handles power operations
type Executor struct {
	cfg       *config.Config
	inventory *config.Inventory
	publisher *sqs.Publisher
	logger    *slog.Logger
	auditFile *os.File
}

// AuditEntry is written to audit.jsonl for every operation
type AuditEntry struct {
	Timestamp   string `json:"timestamp"`
	Node        string `json:"node"`
	Action      string `json:"action"`
	Status      string `json:"status"`
	Message     string `json:"message"`
	RequestID   string `json:"request_id"`
	Vendor      string `json:"vendor"`
	SystemID    string `json:"system_id"`
	User        string `json:"user"`
	Operator    string `json:"operator"`
	Reason      string `json:"reason"`
	HTTPCode    int    `json:"http_code,omitempty"`
	DurationMs  int64  `json:"duration_ms,omitempty"`
}

// NewExecutor creates an operation executor
func NewExecutor(cfg *config.Config, inv *config.Inventory, pub *sqs.Publisher, logger *slog.Logger) (*Executor, error) {
	f, err := os.OpenFile(cfg.AuditLogPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return nil, fmt.Errorf("open audit log %s: %w", cfg.AuditLogPath, err)
	}
	return &Executor{
		cfg:       cfg,
		inventory: inv,
		publisher: pub,
		logger:    logger,
		auditFile: f,
	}, nil
}

// Execute runs a power operation for a received SQS message
func (e *Executor) Execute(ctx context.Context, msg sqs.ReceivedMessage) {
	payload := msg.Envelope.Payload
	startTime := time.Now()

	e.logger.Info("executing operation",
		"node", payload.Node,
		"action", payload.Action,
		"mode", payload.Mode,
		"request_id", payload.RequestID,
	)

	// Validate node exists in inventory
	node, ok := e.inventory.Nodes[payload.Node]
	if !ok {
		e.fail(ctx, msg, "node not found in inventory", 0)
		return
	}

	// Validate action is allowed
	if !isAllowed(node.Allowed, payload.Action) {
		e.fail(ctx, msg, fmt.Sprintf("action %s not allowed for node %s", payload.Action, payload.Node), 0)
		return
	}

	// Resolve vendor, system ID, credentials
	vendor := node.Vendor
	if vendor == "" {
		vendor = detectVendor(payload.Node)
	}
	systemID := config.ResolveSystemID(vendor)
	user, pass := e.cfg.ResolveCredentials(node)

	// Publish progress: validating → accepted
	e.publishProgress(ctx, msg, "validating", 10)

	// Handle status check separately
	if payload.Action == "status" {
		e.handleStatus(ctx, msg, node, systemID, user, pass, vendor)
		return
	}

	// Build Redfish client and execute reset
	rfClient := redfish.NewClient(user, pass, e.cfg.RedfishTLSVerify, e.cfg.RedfishTimeout)
	resetType := redfish.ResolveResetType(payload.Action, payload.Mode)

	httpCode, respBody, err := rfClient.Reset(node.BMCHost, systemID, resetType)
	if err != nil {
		e.fail(ctx, msg, fmt.Sprintf("Redfish error: %v", err), 0)
		return
	}

	if httpCode != 200 && httpCode != 204 {
		e.fail(ctx, msg, fmt.Sprintf("Redfish %s failed (HTTP %d): %s", resetType, httpCode, respBody), httpCode)
		return
	}

	// Publish progress: Redfish accepted
	e.publishProgress(ctx, msg, "redfish_accepted", 30)

	// Publish final success
	duration := time.Since(startTime)
	completedAt := time.Now().UTC().Format(time.RFC3339)
	durationSec := int(duration.Seconds())

	result := sqs.ResponsePayload{
		RequestID:       payload.RequestID,
		Node:            payload.Node,
		Action:          payload.Action,
		Status:          "COMPLETED",
		Phase:           "completed",
		Message:         fmt.Sprintf("Redfish %s accepted (HTTP %d) [system=%s, user=%s]", resetType, httpCode, systemID, user),
		ProgressPct:     100,
		Vendor:          vendor,
		SystemID:        systemID,
		BMCHTTPCode:     httpCode,
		StartedAt:       startTime.UTC().Format(time.RFC3339),
		CompletedAt:     &completedAt,
		DurationSeconds: &durationSec,
	}

	_ = e.publisher.PublishResult(ctx, msg.Envelope.CorrelationID, result)

	// Audit
	e.audit(AuditEntry{
		Timestamp:  time.Now().UTC().Format(time.RFC3339),
		Node:       payload.Node,
		Action:     payload.Action,
		Status:     "SUCCESS",
		Message:    result.Message,
		RequestID:  payload.RequestID,
		Vendor:     vendor,
		SystemID:   systemID,
		User:       user,
		Operator:   payload.Operator,
		Reason:     payload.Reason,
		HTTPCode:   httpCode,
		DurationMs: duration.Milliseconds(),
	})

	e.logger.Info("operation completed",
		"node", payload.Node,
		"action", payload.Action,
		"http_code", httpCode,
		"duration_ms", duration.Milliseconds(),
	)
}

func (e *Executor) handleStatus(ctx context.Context, msg sqs.ReceivedMessage, node config.NodeEntry, systemID, user, pass, vendor string) {
	rfClient := redfish.NewClient(user, pass, e.cfg.RedfishTLSVerify, e.cfg.RedfishTimeout)
	powerState, err := rfClient.GetPowerState(node.BMCHost, systemID)
	if err != nil {
		powerState = "Unknown"
	}

	completedAt := time.Now().UTC().Format(time.RFC3339)
	result := sqs.ResponsePayload{
		RequestID:   msg.Envelope.Payload.RequestID,
		Node:        msg.Envelope.Payload.Node,
		Action:      "status",
		Status:      "COMPLETED",
		Phase:       "completed",
		Message:     fmt.Sprintf("power=%s, vendor=%s, system_id=%s", powerState, vendor, systemID),
		ProgressPct: 100,
		Vendor:      vendor,
		SystemID:    systemID,
		CompletedAt: &completedAt,
	}
	_ = e.publisher.PublishResult(ctx, msg.Envelope.CorrelationID, result)
}

func (e *Executor) fail(ctx context.Context, msg sqs.ReceivedMessage, message string, httpCode int) {
	payload := msg.Envelope.Payload
	e.logger.Error("operation failed", "node", payload.Node, "action", payload.Action, "error", message)

	result := sqs.ResponsePayload{
		RequestID:   payload.RequestID,
		Node:        payload.Node,
		Action:      payload.Action,
		Status:      "FAILED",
		Phase:       "failed",
		Message:     message,
		ProgressPct: 0,
		BMCHTTPCode: httpCode,
	}
	_ = e.publisher.PublishResult(ctx, msg.Envelope.CorrelationID, result)

	e.audit(AuditEntry{
		Timestamp: time.Now().UTC().Format(time.RFC3339),
		Node:      payload.Node,
		Action:    payload.Action,
		Status:    "FAILED",
		Message:   message,
		RequestID: payload.RequestID,
		Operator:  payload.Operator,
		Reason:    payload.Reason,
		HTTPCode:  httpCode,
	})
}

func (e *Executor) publishProgress(ctx context.Context, msg sqs.ReceivedMessage, phase string, pct int) {
	payload := msg.Envelope.Payload
	progress := sqs.ResponsePayload{
		RequestID:   payload.RequestID,
		Node:        payload.Node,
		Action:      payload.Action,
		Status:      "IN_PROGRESS",
		Phase:       phase,
		Message:     fmt.Sprintf("Phase: %s", phase),
		ProgressPct: pct,
	}
	_ = e.publisher.PublishProgress(ctx, msg.Envelope.CorrelationID, progress)
}

func (e *Executor) audit(entry AuditEntry) {
	data, _ := json.Marshal(entry)
	data = append(data, '\n')
	_, _ = e.auditFile.Write(data)
}

func isAllowed(allowed []string, action string) bool {
	for _, a := range allowed {
		if a == action {
			return true
		}
	}
	return false
}

func detectVendor(nodeName string) string {
	switch {
	case contains(nodeName, "dgx"):
		return "dgx"
	case contains(nodeName, "r660") || contains(nodeName, "r750") || contains(nodeName, "r760"):
		return "idrac"
	default:
		return "ilo"
	}
}

func contains(s, substr string) bool {
	return len(s) >= len(substr) && (s == substr || len(s) > 0 && containsStr(s, substr))
}

func containsStr(s, substr string) bool {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}

// Close closes the audit file
func (e *Executor) Close() {
	_ = e.auditFile.Close()
}
