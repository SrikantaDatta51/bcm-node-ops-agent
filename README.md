# BCM Node Operations Agent

SQS-driven agent that polls for node operation requests, executes them via Redfish/cmsh, and publishes results to SNS. Runs on the **BCM head node** as a single systemd service. No containers.

![Architecture](docs/images/architecture.png)

---

## How It Works

```
SQS Queue  ──poll──▶  agent.sh  ──dispatch──▶  operations.sh  ──▶  Redfish BMC / cmsh
                         │                                               │
                         │◀──────────── result ──────────────────────────┘
                         │
                    publish result
                         │
                         ▼
                    SNS Topic
```

1. **agent.sh** (systemd service) long-polls the SQS queue
2. Receives a message: `{"node":"dgx-b200-017", "action":"reboot", "mode":"graceful"}`
3. Dispatches to the matching function in **operations.sh**
4. operations.sh executes the Redfish curl / cmsh command
5. Polls node status until it reaches expected state
6. Publishes result JSON to SNS topic
7. Deletes the SQS message
8. Logs everything to `/var/log/bcm-node-ops/audit.jsonl`

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
├── scripts/
│   ├── agent.sh          # SQS poller → executor → SNS publisher (DON'T EDIT)
│   ├── operations.sh     # Redfish + cmsh commands (YOU EDIT THIS)
│   └── install.sh        # One-time installer
│
├── config/
│   ├── agent.conf        # SQS/SNS endpoints + credentials (YOU EDIT THIS)
│   └── nodes.yaml        # Node inventory — BMC IPs (YOU EDIT THIS)
│
├── systemd/
│   └── bcm-node-ops-agent.service   # ONE systemd unit
│
├── tests/
│   └── test-agent.sh     # Validation tests
│
└── docs/images/
    └── architecture.png
```

**Total: 7 files.** That's it.

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

# Your BMC credentials
REDFISH_USER=admin
REDFISH_PASSWORD=your-real-password
```

**`config/nodes.yaml`** — Add your nodes with real BMC IPs:

```yaml
nodes:
  dgx-b200-017:
    type: gpu
    bmc_host: https://10.10.20.17       # ← your BMC IP
    allowed: [status, reboot, power_on, power_off, power_cycle]

  cpu-r660-004:
    type: cpu
    bmc_host: https://10.10.30.4        # ← your BMC IP
    allowed: [status, reboot, power_on, power_off, power_cycle]
```

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

### Step 4 — Test Manually (No SQS Needed)

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

### Step 5 — Start the Agent (SQS Polling)

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

### Step 6 — Verify

```bash
# Service status
sudo systemctl status bcm-node-ops-agent

# Audit log
cat /var/log/bcm-node-ops/audit.jsonl | python3 -m json.tool --json-lines

# Agent log
tail -f /var/log/bcm-node-ops/agent.log
```

---

## SQS Message Format

Send this JSON to the SQS queue to trigger an operation:

```json
{
  "request_id": "req-001",
  "node": "dgx-b200-017",
  "action": "reboot",
  "mode": "graceful",
  "reason": "firmware upgrade"
}
```

| Field | Required | Values |
|-------|:--------:|--------|
| `request_id` | yes | Unique ID for tracking |
| `node` | yes | Must exist in `nodes.yaml` |
| `action` | yes | `reboot`, `power_on`, `power_off`, `power_cycle`, `status` |
| `mode` | no | `graceful` (default), `force` |
| `reason` | no | Free text, logged in audit |

## SNS Result Format

The agent publishes this to the SNS results topic after execution:

```json
{
  "request_id": "req-001",
  "node": "dgx-b200-017",
  "action": "reboot",
  "status": "SUCCESS",
  "message": "Redfish GracefulRestart accepted (HTTP 204)",
  "timestamp": "2026-06-16T06:00:00Z"
}
```

---

## Customizing Operations

Edit `/opt/bcm-node-ops/scripts/operations.sh`. Each operation is a bash function:

```bash
# Example: Change reboot to use a different Redfish endpoint
do_reboot() {
    local node="$1" bmc="$2" mode="${3:-graceful}" reason="$4"
    local reset_type="GracefulRestart"
    [[ "$mode" == "force" ]] && reset_type="ForceRestart"

    # ← Change this curl command to match your BMC
    http_code=$(curl -sk -u "${REDFISH_USER}:${REDFISH_PASSWORD}" \
        -o /dev/null -w "%{http_code}" \
        -X POST -H "Content-Type: application/json" \
        -d "{\"ResetType\":\"${reset_type}\"}" \
        "${bmc}/redfish/v1/Systems/1/Actions/ComputerSystem.Reset")

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
| Redfish timeout | `curl -k https://<bmc-ip>/redfish/v1/Systems/1` |
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
