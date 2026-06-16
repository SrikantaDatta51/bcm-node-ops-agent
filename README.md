# BCM Node Operations Agent

SQS-driven agent that subscribes to a request queue, executes **vendor-aware Redfish** power operations, and publishes results to a response queue. Runs on the **BCM head node** as a systemd service. No containers. **Dual-mode: Go binary (production) or shell script (quick-edit).**

**Jira:** ALTUS-20280 (API Power Operation — Reboot/Off/On) | **Parent:** ALTUS-18358

### Supported BMC Vendors

| Vendor | BMC Product | System ID | Redfish Path |
|--------|-------------|-----------|-------------|
| **NVIDIA DGX** | AMI Redfish Server | `DGX` | `/redfish/v1/Systems/DGX/Actions/ComputerSystem.Reset` |
| **Dell iDRAC** | iDRAC 8/9/10 | `System.Embedded.1` | `/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset` |
| **HPE iLO** | iLO 4/5/6 | `1` | `/redfish/v1/Systems/1/Actions/ComputerSystem.Reset` |

> 📖 Full curl reference for all three vendors: [docs/redfish-reference.md](docs/redfish-reference.md)

### Agent Modes

| Mode | Binary | systemd Unit | SQS Model | Use Case |
|------|--------|-------------|-----------|----------|
| **Go binary** | `bcm-node-ops-agent` | `bcm-node-ops-agent-go.service` | True long-poll (WaitTimeSeconds=20) | Production |
| **Shell script** | `scripts/agent.sh` | `bcm-node-ops-agent.service` | SQS polling (configurable interval) | Quick iteration |

Both modes share the same `config/nodes.yaml` inventory and `config/agent.conf`/`agent.env` credentials.

---

## How It Works

```
SQS Request Queue ──subscribe──▶  Agent (Go/Shell)  ──dispatch──▶  Redfish BMC
                                       │                               │
                                       │◀──────── result ──────────────┘
                                       │
                                  publish progress
                                       │
                                       ▼
                                SQS Response Queue ──▶ Fleet API (progress + result)
```

1. Agent subscribes to `fleet-node-ops-requests` SQS (Go: true long-poll, Shell: polling loop)
2. Receives standardized message envelope with payload
3. Checks TTL — expired requests are discarded with EXPIRED response
4. Resolves vendor → Redfish System ID, resolves credentials (node → vendor → global)
5. Publishes progress: `validating` → `redfish_accepted` → `completed`/`failed`
6. Writes audit entry to `/var/log/bcm-node-ops/audit.jsonl`

---

## What You Edit

| File | What | When |
|------|------|------|
| `config/agent.conf` | SQS/SNS endpoints, Redfish credentials | **Always** — set your real values |
| `config/nodes.yaml` | Node inventory — BMC IPs, allowed actions | **Always** — add your nodes |
| `scripts/operations.sh` | Redfish curl commands, cmsh commands | **Only if** you need to change the actual reboot/power commands |

Everything else is the agent framework — you don't touch it.

---

## Repo Layout

```
bcm-node-ops-agent/
├── cmd/
│   └── agent/
│       └── main.go              # Go agent entry point
├── internal/
│   ├── config/config.go         # Config loader + credential resolver
│   ├── redfish/client.go        # Vendor-aware Redfish client
│   ├── sqs/consumer.go          # SQS long-poll consumer
│   ├── sqs/publisher.go         # SQS response publisher
│   └── ops/executor.go          # Power operation executor
│
├── scripts/
│   ├── agent.sh                 # Shell agent (polling mode)
│   ├── operations.sh            # Redfish + cmsh commands
│   └── install.sh               # One-time installer
│
├── config/
│   ├── agent.conf               # Shell agent config
│   ├── agent.env                # Go agent env vars (systemd)
│   └── nodes.yaml               # Node inventory + per-node creds
│
├── systemd/
│   ├── bcm-node-ops-agent.service      # Shell agent systemd unit
│   └── bcm-node-ops-agent-go.service   # Go agent systemd unit
│
├── docs/
│   └── redfish-reference.md     # Vendor curl reference
│
├── go.mod                       # Go module
├── Makefile                     # Build/install targets
└── tests/
    └── test-agent.sh            # Validation tests
```

### What You Edit

| File | What | When |
|------|------|------|
| `config/nodes.yaml` | Node inventory — BMC IPs, vendor, per-node creds | **Always** |
| `config/agent.conf` | Shell agent: SQS URLs, per-vendor creds | Shell mode |
| `config/agent.env` | Go agent: SQS URLs, per-vendor creds | Go mode |
| `scripts/operations.sh` | Redfish curl commands | Only if changing shell ops |

---

## Quick Start

### Step 1 — Clone to BCM Head Node

```bash
git clone https://github.com/SrikantaDatta51/bcm-node-ops-agent.git
cd bcm-node-ops-agent
```

### Step 2 — Edit Your Config

**`config/agent.conf`** — Set your SQS/SNS endpoints and BMC credentials:

```bash
# Replace these with your real AWS endpoints
SQS_QUEUE_URL="https://sqs.us-east-1.amazonaws.com/123456789012/bcm-node-ops-requests"
SNS_TOPIC_ARN="arn:aws:sns:us-east-1:123456789012:bcm-node-ops-results"
AWS_REGION="us-east-1"

# Per-vendor BMC credentials (GPU and CPU nodes have different logins)
REDFISH_USER_DGX=coupangdgx
REDFISH_PASSWORD_DGX='your-dgx-password'

REDFISH_USER_IDRAC=root
REDFISH_PASSWORD_IDRAC='your-idrac-password$3!'   # single quotes for $ or !

REDFISH_USER_ILO=pang
REDFISH_PASSWORD_ILO='your-ilo-password'

# Global fallback (used if vendor-specific vars are not set)
REDFISH_USER=admin
REDFISH_PASSWORD=changeme
```

**`config/nodes.yaml`** — Add your nodes with real BMC IPs and vendor:

```yaml
nodes:
  dgx-b200-017:
    type: gpu
    vendor: dgx                          # ← DGX → /Systems/DGX/
    bmc_host: https://10.10.20.17        # ← uses REDFISH_USER_DGX creds
    allowed: [status, reboot, power_on, power_off, power_cycle]

  dgx-h200-042:
    type: gpu
    vendor: dgx
    bmc_host: https://10.10.10.42
    bmc_user: special-user               # ← per-node override (highest priority)
    bmc_password: 'special-pass'
    allowed: [status, reboot, power_on, power_off, power_cycle]

  cpu-r660-004:
    type: cpu
    vendor: idrac                        # ← Dell → /Systems/System.Embedded.1/
    bmc_host: https://10.10.30.4         # ← uses REDFISH_USER_IDRAC creds
    allowed: [status, reboot, power_on, power_off, power_cycle]
```

**Credential resolution priority:**
1. **Per-node** — `bmc_user` / `bmc_password` in nodes.yaml (highest)
2. **Per-vendor** — `REDFISH_USER_DGX` / `REDFISH_PASSWORD_DGX` in agent.conf
3. **Global** — `REDFISH_USER` / `REDFISH_PASSWORD` in agent.conf (fallback)

### Step 3 — Install

```bash
sudo bash scripts/install.sh
```

This installs:
- **jq** (JSON parser)
- **AWS CLI v2** (for SQS/SNS)
- Copies scripts + config to `/opt/bcm-node-ops/`
- Installs one systemd unit
- Enables the service

### Step 4 — Verify SQS/SNS Connectivity (Prereq for Agent Mode)

Before starting the agent, confirm the BCM head node can reach AWS SQS and SNS.

**4a. Configure AWS CLI credentials:**

```bash
aws configure
# AWS Access Key ID:     <your-key>
# AWS Secret Access Key: <your-secret>
# Default region:        us-east-1        (must match agent.conf)
# Default output format: json

# Verify identity
aws sts get-caller-identity
```

**4b. Test SQS — Can you read from the queue?**

```bash
# Replace with your real queue URL from agent.conf
SQS_URL="https://sqs.us-east-1.amazonaws.com/123456789012/bcm-node-ops-requests"

# Receive (will return empty if no messages — that's OK)
aws sqs receive-message --queue-url "$SQS_URL" --max-number-of-messages 1 --wait-time-seconds 5
# ✓ Success: returns {} or {"Messages":[...]}
# ✗ Failure: "Could not connect" or "Access Denied"

# Send a test message to yourself
aws sqs send-message --queue-url "$SQS_URL" \
  --message-body '{"request_id":"connectivity-test","node":"dgx-b200-017","action":"status","reason":"testing SQS"}'
# ✓ Success: returns {"MD5OfMessageBody":"...","MessageId":"..."}

# Read it back
aws sqs receive-message --queue-url "$SQS_URL" --max-number-of-messages 1
# ✓ You should see the message you just sent
```

**4c. Test SNS — Can you publish results?**

```bash
# Replace with your real topic ARN from agent.conf
SNS_ARN="arn:aws:sns:us-east-1:123456789012:bcm-node-ops-results"

aws sns publish --topic-arn "$SNS_ARN" \
  --subject "connectivity-test" \
  --message '{"test":"BCM head node can reach SNS"}'
# ✓ Success: returns {"MessageId":"..."}
# ✗ Failure: "Could not connect" or "AuthorizationError"
```

**4d. Test Redfish BMC — Can you reach the node BMC?**

```bash
# Replace with a real BMC IP from nodes.yaml
# Use the correct System ID for your vendor:
#   DGX:   /Systems/DGX
#   iDRAC: /Systems/System.Embedded.1
#   iLO:   /Systems/1
curl -sk -u admin:your-password https://10.10.20.17/redfish/v1/Systems/DGX | jq '.PowerState, .Status.Health'
# ✓ Success: "On", "OK"
# ✗ Failure: timeout or connection refused

# Don't know the System ID? Discover it:
curl -sk -u admin:your-password https://10.10.20.17/redfish/v1/Systems \
  | python3 -c "import sys,json; d=json.load(sys.stdin); [print(m['@odata.id']) for m in d['Members']]"
```

> **If SQS/SNS is not reachable yet**, skip to Step 5 and test with manual mode. The agent's SQS polling will fail gracefully and retry — you can start the service once connectivity is established.

### Step 5 — Test Manually (No SQS Needed)

```bash
# Check node status via cmsh
/opt/bcm-node-ops/scripts/agent.sh manual dgx-b200-017 status

# Reboot (graceful)
/opt/bcm-node-ops/scripts/agent.sh manual dgx-b200-017 reboot graceful "test reboot"

# Reboot (force — no OS shutdown)
/opt/bcm-node-ops/scripts/agent.sh manual dgx-b200-017 reboot force "node hung"

# Power off (graceful)
/opt/bcm-node-ops/scripts/agent.sh manual dgx-b200-017 power_off graceful "maintenance"

# Power on
/opt/bcm-node-ops/scripts/agent.sh manual dgx-b200-017 power_on

# Power cycle
/opt/bcm-node-ops/scripts/agent.sh manual dgx-b200-017 power_cycle
```

### Step 6 — Start the Agent (SQS Polling)

```bash
sudo systemctl start bcm-node-ops-agent
sudo journalctl -u bcm-node-ops-agent -f
```

You'll see:

```
BCM Node Ops Agent starting
  SQS Queue:  https://sqs.us-east-1.amazonaws.com/123456789012/bcm-node-ops-requests
  SNS Topic:  arn:aws:sns:us-east-1:123456789012:bcm-node-ops-results
  Inventory:  /opt/bcm-node-ops/config/nodes.yaml
  Poll:       every 10s (long-poll 20s)
```

### Step 7 — Verify

```bash
# Service status
sudo systemctl status bcm-node-ops-agent

# Audit log
cat /var/log/bcm-node-ops/audit.jsonl | python3 -m json.tool --json-lines

# Agent log
tail -f /var/log/bcm-node-ops/agent.log
```

---

## SQS Message Format (Standardized Envelope)

All messages use a common envelope. Only `payload` varies per use case.

### Request Message (`fleet-node-ops-requests`)

```json
{
  "message_id": "uuid-v4",
  "message_version": "1.0",
  "timestamp": "2026-06-16T18:00:00Z",
  "source": "fleet-api",
  "correlation_id": "uuid-v4",
  "idempotency_key": "uuid-v4",
  "sequence_number": 10001,
  "ttl_seconds": 300,
  "payload": {
    "request_id": "req-001",
    "node": "dgx-b200-017",
    "action": "reboot",
    "mode": "graceful",
    "reason": "firmware upgrade",
    "operator": "platform-engineer",
    "ticket": "ALTUS-20280"
  }
}
```

### Response Message (`fleet-node-ops-responses`)

```json
{
  "message_id": "uuid-v4",
  "message_version": "1.0",
  "timestamp": "2026-06-16T18:00:05Z",
  "source": "bcm-node-ops-agent",
  "correlation_id": "uuid-v4",
  "idempotency_key": "uuid-v4",
  "sequence_number": 20001,
  "response": {
    "request_id": "req-001",
    "node": "dgx-b200-017",
    "action": "reboot",
    "status": "COMPLETED",
    "phase": "completed",
    "message": "Redfish GracefulRestart accepted (HTTP 204) [system=DGX, user=coupangdgx]",
    "progress_pct": 100,
    "vendor": "dgx",
    "system_id": "DGX",
    "bmc_http_code": 204
  }
}
```

**Progress phases:** `queued` → `validating` → `redfish_accepted` → `polling_status` → `completed` / `failed` / `expired` / `superseded`

---

## Go Agent Quick Start

The Go binary uses **true SQS long-polling** (WaitTimeSeconds=20) — no sleep loops.

### Build

```bash
make build
# → ./bcm-node-ops-agent
```

### Configure

```bash
# Edit agent.env with your real SQS queue URLs and Redfish credentials
vi config/agent.env
```

### Run (Manual)

```bash
source config/agent.env
./bcm-node-ops-agent
```

### Run (systemd)

```bash
make install
sudo systemctl enable --now bcm-node-ops-agent-go
sudo journalctl -u bcm-node-ops-agent-go -f
```

### Key Differences from Shell Agent

| Feature | Go Binary | Shell Script |
|---------|-----------|-------------|
| SQS model | True long-poll (WaitTimeSeconds=20) | Polling with sleep loop |
| Startup | systemd Type=notify | Type=simple |
| Shutdown | Graceful SIGTERM handling | Basic trap |
| Logging | Structured JSON (slog) | Plain text |
| Config | Environment variables (agent.env) | Sourced shell vars (agent.conf) |
| Binary | Single static binary | Requires bash, curl, jq, aws-cli |

---

## Customizing Operations

Edit `/opt/bcm-node-ops/scripts/operations.sh`. Each operation is a bash function:

```bash
# All functions receive system_id as $5 (resolved from vendor in nodes.yaml)
do_reboot() {
    local node="$1" bmc="$2" mode="${3:-graceful}" reason="$4" system_id="${5:-1}"
    local reset_type="GracefulRestart"
    [[ "$mode" == "force" ]] && reset_type="ForceRestart"

    # system_id is auto-resolved from vendor field:
    #   dgx   → DGX
    #   idrac → System.Embedded.1
    #   ilo   → 1
    http_code=$(curl -sk -u "${REDFISH_USER}:${REDFISH_PASSWORD}" \
        -o /dev/null -w "%{http_code}" \
        -X POST -H "Content-Type: application/json" \
        -d "{\"ResetType\":\"${reset_type}\"}" \
        "${bmc}/redfish/v1/Systems/${system_id}/Actions/ComputerSystem.Reset")

    [[ "$http_code" =~ ^(200|204)$ ]] && echo "OK" || { echo "FAIL (HTTP $http_code)"; return 1; }
}
```

Available functions to edit:

| Function | Called When |
|----------|------------|
| `do_reboot` | action = `reboot` |
| `do_power_on` | action = `power_on` |
| `do_power_off` | action = `power_off` |
| `do_power_cycle` | action = `power_cycle` |
| `do_status` | action = `status` |
| `poll_status_after_action` | After any power operation completes |

---

## Run Tests

```bash
bash tests/test-agent.sh
```

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| `aws: command not found` | Run `sudo bash scripts/install.sh` |
| `jq: command not found` | Run `sudo bash scripts/install.sh` |
| SQS poll errors | Check `aws configure` — need valid IAM credentials |
| `Node not in inventory` | Add to `/opt/bcm-node-ops/config/nodes.yaml` |
| `Action not allowed` | Check `allowed:` list for the node in `nodes.yaml` |
| Redfish timeout | `curl -k https://<bmc-ip>/redfish/v1/Systems` (discover System ID first) |
| Agent won't start | `sudo journalctl -u bcm-node-ops-agent -n 50` |

---

## Security

| Layer | Control |
|-------|---------|
| Node validation | Only nodes in `nodes.yaml` — no user-supplied BMC hosts |
| Action validation | Per-node `allowed` list |
| Input sanitization | `^[a-zA-Z0-9._-]+$` — rejects injection |
| Credentials | `agent.conf` file, never logged |
| systemd hardening | `NoNewPrivileges`, `PrivateTmp`, `ProtectSystem=strict` |
| Audit trail | Every operation → `/var/log/bcm-node-ops/audit.jsonl` |
