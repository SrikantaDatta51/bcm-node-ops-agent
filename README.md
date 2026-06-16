# BCM Node Operations Agent

Kestra-based node lifecycle agent for BCM-managed GPU/CPU fleets. Runs on the **BCM head node** as a Docker container managed by systemd. No REST API — operations are executed via Kestra flows that invoke systemd-wrapped shell scripts.

![Architecture](docs/images/architecture.png)

---

## What It Does

| Operation | Method | Script |
|-----------|--------|--------|
| **Reboot** (graceful/force) | Redfish `ComputerSystem.Reset` | `scripts/redfish-reboot.sh` |
| **Power On** | Redfish `ResetType: On` | `scripts/redfish-power-on.sh` |
| **Power Off** (graceful/force) | Redfish `GracefulShutdown` / `ForceOff` | `scripts/redfish-power-off.sh` |
| **Power Cycle** | Redfish `ResetType: PowerCycle` | `scripts/redfish-power-cycle.sh` |
| **Status Check** | BCM `cmsh` | `scripts/node-status.sh` |

Supports both **GPU nodes** (DGX B200, H200) and **CPU nodes** (Dell R660).

### Redfish ResetType Mapping

| Action | Mode | Redfish ResetType |
|--------|------|-------------------|
| Reboot | graceful | GracefulRestart |
| Reboot | force | ForceRestart |
| Power On | — | On |
| Power Off | graceful | GracefulShutdown |
| Power Off | force | ForceOff |
| Power Cycle | — | PowerCycle |

---

## Repository Layout

```
bcm-node-ops-agent/
├── scripts/                      # Shell scripts (the actual operations)
│   ├── common.sh                 #   Shared: logging, inventory lookup, Redfish helper
│   ├── node-status.sh            #   cmsh status check
│   ├── redfish-reboot.sh         #   Redfish reboot (graceful/force)
│   ├── redfish-power-on.sh       #   Redfish power on
│   ├── redfish-power-off.sh      #   Redfish power off (graceful/force)
│   └── redfish-power-cycle.sh    #   Redfish power cycle
│
├── kestra/                       # Kestra configuration
│   ├── application.yaml          #   Kestra standalone config
│   └── flows/                    #   Kestra flow definitions
│       ├── node-reboot.yaml
│       ├── node-power-on.yaml
│       ├── node-power-off.yaml
│       ├── node-power-cycle.yaml
│       ├── node-status.yaml
│       └── fleet-health-report.yaml
│
├── systemd/                      # systemd service units
│   ├── bcm-node-ops-agent.service    # Main agent (Docker Compose)
│   ├── node-status@.service
│   ├── node-reboot@.service
│   ├── node-power-on@.service
│   ├── node-power-off@.service
│   └── node-power-cycle@.service
│
├── config/
│   └── nodes.yaml                # Node inventory (BMC IPs, allowed actions)
│
├── docker-compose.yaml           # Kestra Agent + PostgreSQL
├── .env.example                  # Environment template
├── tests/
│   └── test-scripts.sh           # Shell script validation tests
└── docs/
    └── images/architecture.png   # Architecture diagram
```

---

## Quick Start: BCM Head Node

### Step 1 — Clone and Configure

```bash
git clone https://github.com/SrikantaDatta51/bcm-node-ops-agent.git /opt/bcm-node-ops
cd /opt/bcm-node-ops
```

### Step 2 — Edit Node Inventory

Edit `config/nodes.yaml` with your actual nodes and BMC IPs:

```yaml
nodes:
  dgx-b200-017:
    type: gpu
    bcm_name: dgx-b200-017
    bmc_host: https://10.10.20.17       # ← your BMC IP
    allowed_actions: [status, reboot, power_on, power_off, power_cycle]
    site: az2
    cluster: az2-prod-bmaas-01

  cpu-r660-004:
    type: cpu
    bcm_name: cpu-r660-004
    bmc_host: https://10.10.30.4        # ← your BMC IP
    allowed_actions: [status, reboot, power_on, power_off, power_cycle]
```

### Step 3 — Set Credentials

```bash
cp .env.example .env
# Edit .env with your Redfish BMC credentials
vim .env
```

```env
REDFISH_USER=admin
REDFISH_PASSWORD=your-actual-bmc-password
REDFISH_TLS_VERIFY=false
```

### Step 4 — Start the Agent

```bash
docker compose up -d
```

This starts:
- **Kestra Agent** (standalone mode — server + worker + UI)
- **PostgreSQL** (Kestra internal state)

Kestra UI: **http://\<bcm-head-ip\>:8080**

### Step 5 — Test: Run Scripts Directly (No Kestra)

```bash
# Set env for direct script testing
source .env
export NODE_INVENTORY_PATH=/opt/bcm-node-ops/config/nodes.yaml
export AUDIT_LOG_DIR=/opt/bcm-node-ops/logs

# Check node status via cmsh
./scripts/node-status.sh dgx-b200-017

# Dry run: check what reboot would do (safe — no Redfish call)
echo "Would call: Redfish GracefulRestart on $(grep -A3 'dgx-b200-017' config/nodes.yaml | grep bmc_host | awk '{print $2}')"

# Reboot via Redfish (⚠ actually reboots the node)
./scripts/redfish-reboot.sh dgx-b200-017 graceful "manual test"

# Power off
./scripts/redfish-power-off.sh dgx-b200-017 graceful "maintenance window"

# Power on
./scripts/redfish-power-on.sh dgx-b200-017 "post-maintenance"

# Power cycle
./scripts/redfish-power-cycle.sh dgx-b200-017 "node unresponsive"
```

### Step 6 — Test: Run Flows via Kestra UI

1. Open **http://\<bcm-head-ip\>:8080**
2. Navigate to **Flows → bcm.node-ops**
3. Select a flow (e.g., `node-reboot`)
4. Click **Execute** with inputs:
   - `node_name`: `dgx-b200-017`
   - `mode`: `graceful`
   - `reason`: `manual test`
   - `dry_run`: `true` ← safe, validates only
5. Check the execution log

### Step 7 — Test: Run Flows via Kestra CLI

```bash
# Dry-run reboot
docker exec bcm-node-ops-kestra /app/kestra flow execute \
  --namespace bcm.node-ops \
  --id node-reboot \
  --input node_name=dgx-b200-017 \
  --input mode=graceful \
  --input reason="CLI test" \
  --input dry_run=true

# Status check
docker exec bcm-node-ops-kestra /app/kestra flow execute \
  --namespace bcm.node-ops \
  --id node-status \
  --input node_name=dgx-b200-017

# Fleet health report (all nodes)
docker exec bcm-node-ops-kestra /app/kestra flow execute \
  --namespace bcm.node-ops \
  --id fleet-health-report
```

### Step 8 — Test: Via systemd (Alternative — No Docker)

```bash
# Direct systemd wrappers (if Docker is not available)
sudo cp systemd/*.service /etc/systemd/system/
sudo systemctl daemon-reload

sudo systemctl start node-status@dgx-b200-017.service
journalctl -u node-status@dgx-b200-017.service --no-pager

sudo systemctl start node-reboot@dgx-b200-017.service
journalctl -u node-reboot@dgx-b200-017.service --no-pager
```

### Step 9 — Check Audit Logs

```bash
# All audit entries
cat logs/audit.jsonl | python3 -m json.tool --json-lines

# Filter by node
grep dgx-b200-017 logs/audit.jsonl

# Filter failures
grep FAILED logs/audit.jsonl
```

### Step 10 — Run Tests

```bash
bash tests/test-scripts.sh
```

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| `cmsh not found` | Expected if not on BCM head node — scripts return mock status |
| `Redfish timeout` | Check BMC reachability: `curl -k https://<bmc-ip>/redfish/v1/Systems/1` |
| `REDFISH_PASSWORD must be set` | Set in `.env` or `export REDFISH_PASSWORD=...` |
| `Node not found in inventory` | Add to `config/nodes.yaml` |
| `Action not allowed` | Check `allowed_actions` for the node in `config/nodes.yaml` |
| Kestra UI not loading | Check: `docker compose logs kestra` |
| PostgreSQL not starting | Check: `docker compose logs kestra-db` |

---

## Phase 2: AWS Integration (Future)

Once network connectivity between BCM head node and AWS is established:

1. Switch Kestra from **standalone** to **worker** mode
2. Worker connects to **Kestra Server** running on AWS
3. Kestra Server receives events from **SNS/SQS**
4. Kestra Server dispatches flows to the **worker on BCM**
5. Results flow back through Kestra Server → **Aurora DB** → **REST API**

```yaml
# Phase 2: docker-compose.yaml change
services:
  kestra:
    command: server worker   # ← switch from "standalone" to "worker"
    environment:
      KESTRA_SERVER_URL: https://kestra.your-aws-domain.com
```

---

## Security

| Layer | Control |
|-------|---------|
| Node validation | Allowlisted in `config/nodes.yaml` — no user-supplied BMC hosts |
| Action validation | Per-node `allowed_actions` list |
| Input sanitization | Regex: `^[a-zA-Z0-9._-]+$` — rejects `; rm -rf`, `$(cmd)`, backticks |
| Shell execution | Only allowlisted scripts via systemd units |
| Credentials | `.env` file (gitignored), never logged |
| systemd hardening | `NoNewPrivileges=true`, `PrivateTmp=true`, `ProtectSystem=strict` |
| Audit trail | Every operation logged to `logs/audit.jsonl` |
