#!/usr/bin/env bash
# redfish-power-on.sh — Power on node via Redfish BMC
# Usage: redfish-power-on.sh <node-name> [reason]
set -euo pipefail
source "$(dirname "$0")/common.sh"

NODE="${1:?Usage: $0 <node-name> [reason]}"
REASON="${2:-manual-power-on}"

validate_node_name "$NODE"
is_action_allowed "$NODE" "power_on"

BMC_HOST=$(lookup_bmc_host "$NODE")
RESET_TYPE="On"

log_info "Powering on $NODE via Redfish $RESET_TYPE (bmc=$BMC_HOST)"

RESULT=$(redfish_reset "$BMC_HOST" "$RESET_TYPE") && STATUS="SUCCESS" || STATUS="FAILED"

emit_audit "$NODE" "power_on" "$STATUS" "$RESET_TYPE" "$RESULT" "$REASON"

if [[ "$STATUS" == "FAILED" ]]; then
    log_error "Power on failed for $NODE: $RESULT"
    exit 1
fi

log_info "Power on successful for $NODE"
echo "$RESULT"
