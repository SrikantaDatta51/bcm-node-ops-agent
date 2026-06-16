package redfish

import (
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// Client is a vendor-aware Redfish client
type Client struct {
	httpClient *http.Client
	user       string
	password   string
}

// SystemStatus holds the power state from Redfish
type SystemStatus struct {
	PowerState string `json:"PowerState"`
	Status     struct {
		Health string `json:"Health"`
		State  string `json:"State"`
	} `json:"Status"`
}

// NewClient creates a Redfish client with credentials and TLS settings
func NewClient(user, password string, tlsVerify bool, timeoutSec int) *Client {
	return &Client{
		httpClient: &http.Client{
			Timeout: time.Duration(timeoutSec) * time.Second,
			Transport: &http.Transport{
				TLSClientConfig: &tls.Config{InsecureSkipVerify: !tlsVerify},
			},
		},
		user:     user,
		password: password,
	}
}

// Reset sends a ComputerSystem.Reset action to the BMC
// Returns (httpStatusCode, responseBody, error)
func (c *Client) Reset(bmcHost, systemID, resetType string) (int, string, error) {
	url := fmt.Sprintf("%s/redfish/v1/Systems/%s/Actions/ComputerSystem.Reset", bmcHost, systemID)
	body := fmt.Sprintf(`{"ResetType":"%s"}`, resetType)

	req, err := http.NewRequest("POST", url, strings.NewReader(body))
	if err != nil {
		return 0, "", fmt.Errorf("build request: %w", err)
	}
	req.SetBasicAuth(c.user, c.password)
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return 0, "", fmt.Errorf("redfish call to %s: %w", url, err)
	}
	defer resp.Body.Close()

	respBody, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(respBody), nil
}

// GetPowerState queries the current power state of a system
func (c *Client) GetPowerState(bmcHost, systemID string) (string, error) {
	url := fmt.Sprintf("%s/redfish/v1/Systems/%s", bmcHost, systemID)

	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return "", fmt.Errorf("build request: %w", err)
	}
	req.SetBasicAuth(c.user, c.password)

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("redfish query %s: %w", url, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return "", fmt.Errorf("redfish returned HTTP %d", resp.StatusCode)
	}

	var status SystemStatus
	if err := json.NewDecoder(resp.Body).Decode(&status); err != nil {
		return "", fmt.Errorf("decode response: %w", err)
	}
	return status.PowerState, nil
}

// ResolveResetType maps action+mode to Redfish ResetType
func ResolveResetType(action, mode string) string {
	switch action {
	case "reboot":
		if mode == "force" {
			return "ForceRestart"
		}
		return "GracefulRestart"
	case "power_off":
		if mode == "force" {
			return "ForceOff"
		}
		return "GracefulShutdown"
	case "power_on":
		return "On"
	case "power_cycle":
		return "PowerCycle"
	default:
		return "GracefulRestart"
	}
}
