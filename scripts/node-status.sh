#!/usr/bin/env bash
# node-status.sh — Get BCM node status via cmsh
# Usage: node-status.sh <node-name> [reason]
set -euo pipefail
source "$(dirname "$0")/common.sh"

NODE="${1:?Usage: $0 <node-name> [reason]}"
REASON="${2:-manual-check}"

validate_node_name "$NODE"
is_action_allowed "$NODE" "status"

NODE_TYPE=$(lookup_node_type "$NODE")
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

log_info "Checking status of $NODE (type=$NODE_TYPE) via cmsh"

# Run cmsh
if command -v cmsh &>/dev/null; then
    OUTPUT=$(cmsh -c "device use ${NODE}; status" 2>&1) || true
else
    log_warn "cmsh not found — returning mock status"
    OUTPUT="Status: UNKNOWN (cmsh not available)"
fi

# Parse status
STATUS="UNKNOWN"
POWER="Unknown"
REACHABLE="false"

if echo "$OUTPUT" | grep -qi "UP"; then
    STATUS="UP"
    POWER="On"
    REACHABLE="true"
elif echo "$OUTPUT" | grep -qi "DOWN\|CLOSED"; then
    STATUS="DOWN"
    POWER="Off"
    REACHABLE="false"
elif echo "$OUTPUT" | grep -qi "INSTALLING\|PROVISIONING"; then
    STATUS="INSTALLING"
    POWER="On"
    REACHABLE="false"
fi

# Build result JSON
RESULT=$(cat <<EOF
{"node":"${NODE}","type":"${NODE_TYPE}","bcm_status":"${STATUS}","power_state":"${POWER}","reachable":${REACHABLE},"last_checked_at":"${TIMESTAMP}"}
EOF
)

# Emit audit log
emit_audit "$NODE" "status" "SUCCESS" "N/A" "bcm_status=${STATUS},power=${POWER}" "$REASON"

# Output result
echo "$RESULT"
