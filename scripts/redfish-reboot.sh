#!/usr/bin/env bash
# redfish-reboot.sh — Reboot node via Redfish BMC
# Usage: redfish-reboot.sh <node-name> [graceful|force] [reason]
set -euo pipefail
source "$(dirname "$0")/common.sh"

NODE="${1:?Usage: $0 <node-name> [graceful|force] [reason]}"
MODE="${2:-graceful}"
REASON="${3:-manual-reboot}"

validate_node_name "$NODE"
is_action_allowed "$NODE" "reboot"

BMC_HOST=$(lookup_bmc_host "$NODE")

RESET_TYPE="GracefulRestart"
[[ "$MODE" == "force" ]] && RESET_TYPE="ForceRestart"

log_info "Rebooting $NODE via Redfish $RESET_TYPE (bmc=$BMC_HOST)"

RESULT=$(redfish_reset "$BMC_HOST" "$RESET_TYPE") && STATUS="SUCCESS" || STATUS="FAILED"

emit_audit "$NODE" "reboot" "$STATUS" "$RESET_TYPE" "$RESULT" "$REASON"

if [[ "$STATUS" == "FAILED" ]]; then
    log_error "Reboot failed for $NODE: $RESULT"
    exit 1
fi

log_info "Reboot successful for $NODE"
echo "$RESULT"
