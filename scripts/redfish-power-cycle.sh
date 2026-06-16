#!/usr/bin/env bash
# redfish-power-cycle.sh — Power cycle node via Redfish BMC
# Usage: redfish-power-cycle.sh <node-name> [reason]
set -euo pipefail
source "$(dirname "$0")/common.sh"

NODE="${1:?Usage: $0 <node-name> [reason]}"
REASON="${2:-manual-power-cycle}"

validate_node_name "$NODE"
is_action_allowed "$NODE" "power_cycle"

BMC_HOST=$(lookup_bmc_host "$NODE")
RESET_TYPE="PowerCycle"

log_info "Power cycling $NODE via Redfish $RESET_TYPE (bmc=$BMC_HOST)"

RESULT=$(redfish_reset "$BMC_HOST" "$RESET_TYPE") && STATUS="SUCCESS" || STATUS="FAILED"

emit_audit "$NODE" "power_cycle" "$STATUS" "$RESET_TYPE" "$RESULT" "$REASON"

if [[ "$STATUS" == "FAILED" ]]; then
    log_error "Power cycle failed for $NODE: $RESULT"
    exit 1
fi

log_info "Power cycle successful for $NODE"
echo "$RESULT"
