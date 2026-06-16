#!/usr/bin/env bash
# redfish-power-off.sh — Power off node via Redfish BMC
# Usage: redfish-power-off.sh <node-name> [graceful|force] [reason]
set -euo pipefail
source "$(dirname "$0")/common.sh"

NODE="${1:?Usage: $0 <node-name> [graceful|force] [reason]}"
MODE="${2:-graceful}"
REASON="${3:-manual-power-off}"

validate_node_name "$NODE"
is_action_allowed "$NODE" "power_off"

BMC_HOST=$(lookup_bmc_host "$NODE")

RESET_TYPE="GracefulShutdown"
[[ "$MODE" == "force" ]] && RESET_TYPE="ForceOff"

log_info "Powering off $NODE via Redfish $RESET_TYPE (bmc=$BMC_HOST)"

RESULT=$(redfish_reset "$BMC_HOST" "$RESET_TYPE") && STATUS="SUCCESS" || STATUS="FAILED"

emit_audit "$NODE" "power_off" "$STATUS" "$RESET_TYPE" "$RESULT" "$REASON"

if [[ "$STATUS" == "FAILED" ]]; then
    log_error "Power off failed for $NODE: $RESULT"
    exit 1
fi

log_info "Power off successful for $NODE"
echo "$RESULT"
