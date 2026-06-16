#!/usr/bin/env bash
# common.sh — Shared functions for BCM Node Ops Agent scripts
# Source this file: source "$(dirname "$0")/common.sh"
set -euo pipefail

# ── Constants ────────────────────────────────────────────────────
AUDIT_LOG="${AUDIT_LOG_DIR:-/var/log/bcm-node-ops}/audit.jsonl"
INVENTORY="${NODE_INVENTORY_PATH:-/opt/bcm-node-ops/config/nodes.yaml}"
REDFISH_USER="${REDFISH_USER:-admin}"
REDFISH_PASSWORD="${REDFISH_PASSWORD:?REDFISH_PASSWORD must be set}"
TLS_VERIFY="${REDFISH_TLS_VERIFY:-false}"
REDFISH_TIMEOUT="${REDFISH_TIMEOUT:-30}"

# ── Logging ──────────────────────────────────────────────────────

log_info()  { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [INFO]  $*" >&2; }
log_warn()  { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [WARN]  $*" >&2; }
log_error() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [ERROR] $*" >&2; }

# ── Audit Log ────────────────────────────────────────────────────

emit_audit() {
    # Usage: emit_audit <node> <action> <status> <reset_type> <message> [<reason>] [<requested_by>]
    local node="$1" action="$2" status="$3" reset_type="$4" message="$5"
    local reason="${6:-}" requested_by="${7:-agent}"
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    mkdir -p "$(dirname "$AUDIT_LOG")"

    local record
    record=$(cat <<EOF
{"timestamp":"${ts}","node":"${node}","action":"${action}","status":"${status}","reset_type":"${reset_type}","message":"${message}","reason":"${reason}","requested_by":"${requested_by}"}
EOF
)
    echo "$record" >> "$AUDIT_LOG"
    # Also emit to stdout for Kestra/Docker log capture
    echo "$record"
}

# ── Node Validation ──────────────────────────────────────────────

validate_node_name() {
    local node="$1"
    if [[ ! "$node" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        log_error "Invalid node name: $node (must match ^[a-zA-Z0-9._-]+\$)"
        return 1
    fi
}

# ── Inventory Lookup ─────────────────────────────────────────────

lookup_bmc_host() {
    # Lookup BMC host from nodes.yaml for a given node name
    # Uses grep+awk for zero-dependency parsing (no yq needed)
    local node="$1"
    local in_node=false bmc_host=""

    while IFS= read -r line; do
        # Match "  node-name:" at 2-space indent
        if [[ "$line" =~ ^[[:space:]]{2}${node}:$ ]] || [[ "$line" =~ ^[[:space:]]{2}\"?${node}\"?:$ ]]; then
            in_node=true
            continue
        fi
        # If we're in the node block, look for bmc_host
        if $in_node; then
            if [[ "$line" =~ ^[[:space:]]{4}bmc_host:[[:space:]]*(.+)$ ]]; then
                bmc_host="${BASH_REMATCH[1]}"
                # Strip quotes if present
                bmc_host="${bmc_host%\"}"
                bmc_host="${bmc_host#\"}"
                bmc_host="${bmc_host%\'}"
                bmc_host="${bmc_host#\'}"
                echo "$bmc_host"
                return 0
            fi
            # If we hit another node (2-space indent key), stop
            if [[ "$line" =~ ^[[:space:]]{2}[a-zA-Z] ]] && [[ ! "$line" =~ ^[[:space:]]{4} ]]; then
                break
            fi
        fi
    done < "$INVENTORY"

    log_error "Node $node not found in inventory: $INVENTORY"
    return 1
}

lookup_node_type() {
    # Lookup node type (gpu/cpu) from nodes.yaml
    local node="$1"
    local in_node=false

    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]{2}${node}:$ ]] || [[ "$line" =~ ^[[:space:]]{2}\"?${node}\"?:$ ]]; then
            in_node=true
            continue
        fi
        if $in_node; then
            if [[ "$line" =~ ^[[:space:]]{4}type:[[:space:]]*(.+)$ ]]; then
                echo "${BASH_REMATCH[1]}"
                return 0
            fi
            if [[ "$line" =~ ^[[:space:]]{2}[a-zA-Z] ]] && [[ ! "$line" =~ ^[[:space:]]{4} ]]; then
                break
            fi
        fi
    done < "$INVENTORY"

    echo "unknown"
}

is_action_allowed() {
    # Check if action is in the node's allowed_actions list
    local node="$1" action="$2"
    local in_node=false

    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]{2}${node}:$ ]] || [[ "$line" =~ ^[[:space:]]{2}\"?${node}\"?:$ ]]; then
            in_node=true
            continue
        fi
        if $in_node; then
            if [[ "$line" =~ allowed_actions.*${action} ]]; then
                return 0
            fi
            if [[ "$line" =~ ^[[:space:]]{2}[a-zA-Z] ]] && [[ ! "$line" =~ ^[[:space:]]{4} ]]; then
                break
            fi
        fi
    done < "$INVENTORY"

    log_error "Action $action not allowed for node $node"
    return 1
}

# ── Redfish Helper ───────────────────────────────────────────────

redfish_reset() {
    # Execute a Redfish ComputerSystem.Reset action
    # Usage: redfish_reset <bmc_host> <reset_type>
    local bmc_host="$1" reset_type="$2"

    local curl_opts=(-s -S -w "\n%{http_code}" --max-time "$REDFISH_TIMEOUT")
    [[ "$TLS_VERIFY" == "false" ]] && curl_opts+=(-k)

    local response
    response=$(curl "${curl_opts[@]}" \
        -u "${REDFISH_USER}:${REDFISH_PASSWORD}" \
        -X POST \
        -H "Content-Type: application/json" \
        -d "{\"ResetType\":\"${reset_type}\"}" \
        "${bmc_host}/redfish/v1/Systems/1/Actions/ComputerSystem.Reset" 2>&1)

    local http_code body
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" =~ ^(200|204)$ ]]; then
        echo "{\"status\":\"SUCCESS\",\"reset_type\":\"${reset_type}\",\"http_status\":${http_code}}"
        return 0
    else
        echo "{\"status\":\"FAILED\",\"reset_type\":\"${reset_type}\",\"http_status\":${http_code},\"error\":\"${body}\"}" >&2
        return 1
    fi
}
