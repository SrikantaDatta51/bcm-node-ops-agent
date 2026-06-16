package sqs

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	"github.com/google/uuid"
)

// ResponsePayload is the power operation response payload
type ResponsePayload struct {
	RequestID       string  `json:"request_id"`
	Node            string  `json:"node"`
	Action          string  `json:"action"`
	Status          string  `json:"status"`
	Phase           string  `json:"phase"`
	Message         string  `json:"message"`
	ProgressPct     int     `json:"progress_pct"`
	Vendor          string  `json:"vendor"`
	SystemID        string  `json:"system_id"`
	BMCHTTPCode     int     `json:"bmc_http_code,omitempty"`
	StartedAt       string  `json:"started_at,omitempty"`
	CompletedAt     *string `json:"completed_at"`
	DurationSeconds *int    `json:"duration_seconds"`
}

// Publisher sends response messages to the response SQS queue
type Publisher struct {
	client   *sqs.Client
	queueURL string
	logger   *slog.Logger
	seq      int64
}

// NewPublisher creates a publisher for the response queue
func NewPublisher(ctx context.Context, queueURL, region string, logger *slog.Logger) (*Publisher, error) {
	cfg, err := awsconfig.LoadDefaultConfig(ctx, awsconfig.WithRegion(region))
	if err != nil {
		return nil, fmt.Errorf("load AWS config: %w", err)
	}
	return &Publisher{
		client:   sqs.NewFromConfig(cfg),
		queueURL: queueURL,
		logger:   logger,
		seq:      time.Now().UnixMilli(), // start from timestamp for uniqueness
	}, nil
}

// PublishProgress sends an IN_PROGRESS response
func (p *Publisher) PublishProgress(ctx context.Context, correlationID *string, payload ResponsePayload) error {
	return p.publish(ctx, correlationID, payload)
}

// PublishResult sends a terminal response (COMPLETED, FAILED, EXPIRED, SUPERSEDED)
func (p *Publisher) PublishResult(ctx context.Context, correlationID *string, payload ResponsePayload) error {
	return p.publish(ctx, correlationID, payload)
}

func (p *Publisher) publish(ctx context.Context, correlationID *string, payload ResponsePayload) error {
	p.seq++
	envelope := Message{
		MessageID:      uuid.NewString(),
		MessageVersion: "1.0",
		Timestamp:      time.Now().UTC().Format(time.RFC3339),
		Source:         "bcm-node-ops-agent",
		CorrelationID:  correlationID,
		IdempotencyKey: uuid.NewString(),
		SequenceNumber: p.seq,
		Payload: OpsPayload{
			RequestID: payload.RequestID,
			Node:      payload.Node,
			Action:    payload.Action,
		},
	}

	// Use a wrapper that includes the full response payload
	fullMsg := struct {
		Message
		ResponsePayload ResponsePayload `json:"response"`
	}{
		Message:         envelope,
		ResponsePayload: payload,
	}

	body, err := json.Marshal(fullMsg)
	if err != nil {
		return fmt.Errorf("marshal response: %w", err)
	}

	_, err = p.client.SendMessage(ctx, &sqs.SendMessageInput{
		QueueUrl:    aws.String(p.queueURL),
		MessageBody: aws.String(string(body)),
	})
	if err != nil {
		return fmt.Errorf("SQS send: %w", err)
	}

	p.logger.Info("published response",
		"request_id", payload.RequestID,
		"node", payload.Node,
		"status", payload.Status,
		"phase", payload.Phase,
	)
	return nil
}
