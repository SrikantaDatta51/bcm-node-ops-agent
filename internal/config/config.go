package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"

	"gopkg.in/yaml.v3"
)

// Config holds all agent configuration
type Config struct {
	// SQS
	RequestQueueURL  string
	ResponseQueueURL string
	AWSRegion        string

	// Redfish credentials (3-tier: node → vendor → global)
	RedfishUserDGX      string
	RedfishPasswordDGX  string
	RedfishUserIDRAC    string
	RedfishPasswordIDRAC string
	RedfishUserILO      string
	RedfishPasswordILO  string
	RedfishUser         string // global fallback
	RedfishPassword     string // global fallback
	RedfishTLSVerify    bool
	RedfishTimeout      int

	// Paths
	NodeInventoryPath string
	AuditLogPath      string
	LogDir            string

	// Polling
	MaxMessages int32
	WaitTime    int32 // SQS long-poll WaitTimeSeconds (max 20)
}

// NodeEntry represents a node in the inventory YAML
type NodeEntry struct {
	Type        string   `yaml:"type"`
	Vendor      string   `yaml:"vendor"`
	BMCHost     string   `yaml:"bmc_host"`
	BMCUser     string   `yaml:"bmc_user"`
	BMCPassword string   `yaml:"bmc_password"`
	Allowed     []string `yaml:"allowed"`
}

// Inventory holds the parsed nodes.yaml
type Inventory struct {
	Nodes map[string]NodeEntry `yaml:"nodes"`
}

// VendorSystemID maps vendor name to Redfish System ID
var VendorSystemID = map[string]string{
	"dgx":   "DGX",
	"idrac": "System.Embedded.1",
	"ilo":   "1",
}

// LoadConfig reads configuration from environment variables
func LoadConfig() *Config {
	return &Config{
		RequestQueueURL:      envOrDefault("SQS_REQUEST_QUEUE_URL", ""),
		ResponseQueueURL:     envOrDefault("SQS_RESPONSE_QUEUE_URL", ""),
		AWSRegion:            envOrDefault("AWS_REGION", "us-east-1"),
		RedfishUserDGX:       envOrDefault("REDFISH_USER_DGX", ""),
		RedfishPasswordDGX:   envOrDefault("REDFISH_PASSWORD_DGX", ""),
		RedfishUserIDRAC:     envOrDefault("REDFISH_USER_IDRAC", ""),
		RedfishPasswordIDRAC: envOrDefault("REDFISH_PASSWORD_IDRAC", ""),
		RedfishUserILO:       envOrDefault("REDFISH_USER_ILO", ""),
		RedfishPasswordILO:   envOrDefault("REDFISH_PASSWORD_ILO", ""),
		RedfishUser:          envOrDefault("REDFISH_USER", "admin"),
		RedfishPassword:      envOrDefault("REDFISH_PASSWORD", "changeme"),
		RedfishTLSVerify:     envOrDefault("REDFISH_TLS_VERIFY", "false") == "true",
		RedfishTimeout:       envOrDefaultInt("REDFISH_TIMEOUT", 30),
		NodeInventoryPath:    envOrDefault("NODE_INVENTORY", "/opt/bcm-node-ops/config/nodes.yaml"),
		AuditLogPath:         envOrDefault("AUDIT_LOG", "/var/log/bcm-node-ops/audit.jsonl"),
		LogDir:               envOrDefault("LOG_DIR", "/var/log/bcm-node-ops"),
		MaxMessages:          int32(envOrDefaultInt("SQS_MAX_MESSAGES", 1)),
		WaitTime:             int32(envOrDefaultInt("SQS_WAIT_TIME", 20)),
	}
}

// LoadInventory parses the nodes.yaml file
func LoadInventory(path string) (*Inventory, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read inventory %s: %w", path, err)
	}
	var inv Inventory
	if err := yaml.Unmarshal(data, &inv); err != nil {
		return nil, fmt.Errorf("parse inventory: %w", err)
	}
	return &inv, nil
}

// ResolveCredentials returns (user, password) for a node using 3-tier resolution:
// 1. Per-node (bmc_user/bmc_password in nodes.yaml)
// 2. Per-vendor (REDFISH_USER_DGX, etc.)
// 3. Global fallback (REDFISH_USER/REDFISH_PASSWORD)
func (c *Config) ResolveCredentials(node NodeEntry) (string, string) {
	// Tier 1: per-node
	if node.BMCUser != "" && node.BMCPassword != "" {
		return node.BMCUser, node.BMCPassword
	}
	// Tier 2: per-vendor
	vendor := strings.ToLower(node.Vendor)
	switch vendor {
	case "dgx":
		if c.RedfishUserDGX != "" {
			return c.RedfishUserDGX, c.RedfishPasswordDGX
		}
	case "idrac":
		if c.RedfishUserIDRAC != "" {
			return c.RedfishUserIDRAC, c.RedfishPasswordIDRAC
		}
	case "ilo":
		if c.RedfishUserILO != "" {
			return c.RedfishUserILO, c.RedfishPasswordILO
		}
	}
	// Tier 3: global
	return c.RedfishUser, c.RedfishPassword
}

// ResolveSystemID returns the Redfish System ID for a vendor
func ResolveSystemID(vendor string) string {
	if sid, ok := VendorSystemID[strings.ToLower(vendor)]; ok {
		return sid
	}
	return "1" // safe default (HPE iLO)
}

func envOrDefault(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func envOrDefaultInt(key string, fallback int) int {
	if v := os.Getenv(key); v != "" {
		if i, err := strconv.Atoi(v); err == nil {
			return i
		}
	}
	return fallback
}
