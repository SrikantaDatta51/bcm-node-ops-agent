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
	"github.com/aws/aws-sdk-go-v2/service/sqs/types"
)

// Message is the standardized envelope for all SQS messages
type Message struct {
	MessageID      string      `json:"message_id"`
	MessageVersion string      `json:"message_version"`
	Timestamp      string      `json:"timestamp"`
	Source         string      `json:"source"`
	CorrelationID  *string     `json:"correlation_id"`
	IdempotencyKey string      `json:"idempotency_key"`
	SequenceNumber int64       `json:"sequence_number"`
	TTLSeconds     *int        `json:"ttl_seconds"`
	Payload        OpsPayload  `json:"payload"`
}

// OpsPayload is the power operation request payload
type OpsPayload struct {
	RequestID string `json:"request_id"`
	Node      string `json:"node"`
	Action    string `json:"action"`
	Mode      string `json:"mode"`
	Reason    string `json:"reason"`
	Operator  string `json:"operator"`
	Ticket    string `json:"ticket"`
	Priority  string `json:"priority"`
}

// Consumer subscribes to an SQS queue with true long-polling
type Consumer struct {
	client     *sqs.Client
	queueURL   string
	maxMessages int32
	waitTime   int32 // seconds (max 20 for SQS long-poll)
	logger     *slog.Logger
}

// NewConsumer creates a new SQS consumer with long-poll subscription
func NewConsumer(ctx context.Context, queueURL, region string, maxMessages, waitTime int32, logger *slog.Logger) (*Consumer, error) {
	cfg, err := awsconfig.LoadDefaultConfig(ctx, awsconfig.WithRegion(region))
	if err != nil {
		return nil, fmt.Errorf("load AWS config: %w", err)
	}
	return &Consumer{
		client:      sqs.NewFromConfig(cfg),
		queueURL:    queueURL,
		maxMessages: maxMessages,
		waitTime:    waitTime,
		logger:      logger,
	}, nil
}

// Receive performs a single long-poll receive. Blocks up to waitTime seconds
// or returns immediately when a message arrives. This is TRUE pub/sub behavior —
// no 30-second sleep loops.
func (c *Consumer) Receive(ctx context.Context) ([]ReceivedMessage, error) {
	input := &sqs.ReceiveMessageInput{
		QueueUrl:            aws.String(c.queueURL),
		MaxNumberOfMessages: c.maxMessages,
		WaitTimeSeconds:     c.waitTime, // Long-poll: blocks until message or timeout
		MessageAttributeNames: []string{"All"},
	}

	result, err := c.client.ReceiveMessage(ctx, input)
	if err != nil {
		return nil, fmt.Errorf("SQS receive: %w", err)
	}

	var msgs []ReceivedMessage
	for _, sqsMsg := range result.Messages {
		var envelope Message
		if err := json.Unmarshal([]byte(aws.ToString(sqsMsg.Body)), &envelope); err != nil {
			c.logger.Warn("failed to parse SQS message", "error", err, "message_id", aws.ToString(sqsMsg.MessageId))
			continue
		}

		msgs = append(msgs, ReceivedMessage{
			Envelope:      envelope,
			ReceiptHandle: aws.ToString(sqsMsg.ReceiptHandle),
			SQSMessageID:  aws.ToString(sqsMsg.MessageId),
		})
	}
	return msgs, nil
}

// Delete acknowledges a message by deleting it from the queue
func (c *Consumer) Delete(ctx context.Context, receiptHandle string) error {
	_, err := c.client.DeleteMessage(ctx, &sqs.DeleteMessageInput{
		QueueUrl:      aws.String(c.queueURL),
		ReceiptHandle: aws.String(receiptHandle),
	})
	return err
}

// ReceivedMessage wraps a parsed SQS message with its receipt handle
type ReceivedMessage struct {
	Envelope      Message
	ReceiptHandle string
	SQSMessageID  string
}

// IsExpired checks if the message TTL has been exceeded
func (m *ReceivedMessage) IsExpired() bool {
	if m.Envelope.TTLSeconds == nil {
		return false
	}
	ts, err := time.Parse(time.RFC3339, m.Envelope.Timestamp)
	if err != nil {
		return false
	}
	age := time.Since(ts).Seconds()
	return age > float64(*m.Envelope.TTLSeconds)
}

// ChangeVisibility extends or reduces the visibility timeout of a message
func (c *Consumer) ChangeVisibility(ctx context.Context, receiptHandle string, timeoutSeconds int32) error {
	_, err := c.client.ChangeMessageVisibility(ctx, &sqs.ChangeMessageVisibilityInput{
		QueueUrl:          aws.String(c.queueURL),
		ReceiptHandle:     aws.String(receiptHandle),
		VisibilityTimeout: timeoutSeconds,
	})
	return err
}

// placeholder to satisfy types import
var _ = types.MessageAttributeValue{}
