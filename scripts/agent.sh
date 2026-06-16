#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════╗
# ║  agent.sh — BCM Node Ops Agent                               ║
# ║                                                               ║
# ║  Polls SQS for operation requests → executes → publishes     ║
# ║  results back to SNS. Runs as a systemd service.              ║
# ║                                                               ║
# ║  YOU DON'T EDIT THIS FILE.                                    ║
# ║  Edit operations.sh for the actual commands.                  ║
# ║  Edit config/agent.conf for endpoints and credentials.        ║
# ╚═══════════════════════════════════════════════════════════════╝
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="${AGENT_CONF:-${SCRIPT_DIR}/../config/agent.conf}"

# ── Load config ─────────────────────────────────────────────────
if [[ ! -f "$CONF" ]]; then
    echo "[FATAL] Config not found: $CONF" >&2
    exit 1
fi
source "$CONF"

# ── Load operations ─────────────────────────────────────────────
source "${SCRIPT_DIR}/operations.sh"

# ── Logging ─────────────────────────────────────────────────────
mkdir -p "$(dirname "$AUDIT_LOG")"
mkdir -p "$LOG_DIR"

log()  { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "${LOG_DIR}/agent.log" >&2; }

audit() {
    # $1=node $2=action $3=status $4=message $5=request_id $6=reason
    local record="{\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"node\":\"$1\",\"action\":\"$2\",\"status\":\"$3\",\"message\":\"$4\",\"request_id\":\"$5\",\"reason\":\"$6\"}"
    echo "$record" >> "$AUDIT_LOG"
    echo "$record"  # also stdout for journald
}

# ── Inventory Lookup ────────────────────────────────────────────
lookup_bmc() {
    local node="$1" in_node=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]{2}${node}: ]]; then in_node=true; continue; fi
        if $in_node; then
            if [[ "$line" =~ bmc_host:[[:space:]]*(.+) ]]; then
                local h="${BASH_REMATCH[1]}"
                h="${h%\"}"; h="${h#\"}"; h="${h%\'}"; h="${h#\'}"
                echo "$h"; return 0
            fi
            [[ "$line" =~ ^[[:space:]]{2}[a-zA-Z] ]] && ! [[ "$line" =~ ^[[:space:]]{4} ]] && break
        fi
    done < "$NODE_INVENTORY"
    return 1
}

is_allowed() {
    local node="$1" action="$2"
    grep -A5 "^  ${node}:" "$NODE_INVENTORY" | grep -q "allowed:.*${action}"
}

validate_node() {
    [[ "$1" =~ ^[a-zA-Z0-9._-]+$ ]] || { log "[REJECT] Bad node name: $1"; return 1; }
}

# ── Execute Action ──────────────────────────────────────────────
execute_action() {
    local node="$1" action="$2" mode="${3:-}" reason="${4:-}" request_id="${5:-}"

    # Validate
    validate_node "$node" || { audit "$node" "$action" "REJECTED" "invalid node name" "$request_id" "$reason"; return 1; }

    local bmc
    bmc=$(lookup_bmc "$node") || { audit "$node" "$action" "REJECTED" "node not in inventory" "$request_id" "$reason"; return 1; }

    is_allowed "$node" "$action" || { audit "$node" "$action" "REJECTED" "action not allowed" "$request_id" "$reason"; return 1; }

    log "[EXEC] node=$node action=$action mode=$mode reason=$reason request_id=$request_id"

    # Dispatch to operation function
    local result="" status="SUCCESS" exit_code=0
    case "$action" in
        reboot)      result=$(do_reboot "$node" "$bmc" "$mode" "$reason")      || exit_code=$? ;;
        power_on)    result=$(do_power_on "$node" "$bmc" "$mode" "$reason")    || exit_code=$? ;;
        power_off)   result=$(do_power_off "$node" "$bmc" "$mode" "$reason")   || exit_code=$? ;;
        power_cycle) result=$(do_power_cycle "$node" "$bmc" "$mode" "$reason") || exit_code=$? ;;
        status)      result=$(do_status "$node" "$bmc" "$mode" "$reason")      || exit_code=$? ;;
        *) result="unknown action: $action"; exit_code=1 ;;
    esac

    [[ $exit_code -ne 0 ]] && status="FAILED"
    audit "$node" "$action" "$status" "$result" "$request_id" "$reason"

    # Post-action status polling (skip for status checks)
    if [[ "$status" == "SUCCESS" && "$action" != "status" ]]; then
        log "[POLL] Polling post-action status for $node..."
        local poll_result
        poll_result=$(poll_status_after_action "$node" "$action") || true
        log "[POLL] $poll_result"
        audit "$node" "${action}_poll" "INFO" "$poll_result" "$request_id" "post-action-poll"
    fi

    return $exit_code
}

# ── SQS Receive → Execute → SNS Publish ────────────────────────
process_sqs_message() {
    local raw="$1"

    # Parse JSON fields (jq required — installed by install.sh)
    local node action mode reason request_id receipt_handle
    node=$(echo "$raw" | jq -r '.Messages[0].Body' | jq -r '.node // empty')
    action=$(echo "$raw" | jq -r '.Messages[0].Body' | jq -r '.action // empty')
    mode=$(echo "$raw" | jq -r '.Messages[0].Body' | jq -r '.mode // "graceful"')
    reason=$(echo "$raw" | jq -r '.Messages[0].Body' | jq -r '.reason // ""')
    request_id=$(echo "$raw" | jq -r '.Messages[0].Body' | jq -r '.request_id // empty')
    receipt_handle=$(echo "$raw" | jq -r '.Messages[0].ReceiptHandle')

    if [[ -z "$node" || -z "$action" ]]; then
        log "[SKIP] Malformed SQS message — missing node or action"
        return 1
    fi

    log "[SQS] Received: node=$node action=$action mode=$mode request_id=$request_id"

    # Execute
    local result_msg="" exec_status="SUCCESS"
    result_msg=$(execute_action "$node" "$action" "$mode" "$reason" "$request_id" 2>&1) || exec_status="FAILED"

    # Publish result to SNS
    local sns_payload
    sns_payload=$(jq -n \
        --arg rid "$request_id" \
        --arg node "$node" \
        --arg action "$action" \
        --arg status "$exec_status" \
        --arg message "$result_msg" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{request_id:$rid, node:$node, action:$action, status:$status, message:$message, timestamp:$ts}')

    log "[SNS] Publishing result: status=$exec_status"
    aws sns publish \
        --region "$AWS_REGION" \
        --topic-arn "$SNS_TOPIC_ARN" \
        --message "$sns_payload" \
        --subject "node-ops-result" 2>&1 | tee -a "${LOG_DIR}/agent.log" || log "[SNS] Publish failed (will retry)"

    # Delete processed message from SQS
    aws sqs delete-message \
        --region "$AWS_REGION" \
        --queue-url "$SQS_QUEUE_URL" \
        --receipt-handle "$receipt_handle" 2>&1 || log "[SQS] Delete failed for receipt: $receipt_handle"

    log "[DONE] node=$node action=$action status=$exec_status"
}

# ── Main Loop ───────────────────────────────────────────────────
main() {
    log "============================================="
    log "BCM Node Ops Agent starting"
    log "  SQS Queue:  $SQS_QUEUE_URL"
    log "  SNS Topic:  $SNS_TOPIC_ARN"
    log "  Inventory:  $NODE_INVENTORY"
    log "  Poll:       every ${POLL_INTERVAL_SECONDS}s (long-poll ${SQS_WAIT_TIME_SECONDS}s)"
    log "============================================="

    while true; do
        # Long-poll SQS
        local response
        response=$(aws sqs receive-message \
            --region "$AWS_REGION" \
            --queue-url "$SQS_QUEUE_URL" \
            --max-number-of-messages "$SQS_MAX_MESSAGES" \
            --wait-time-seconds "$SQS_WAIT_TIME_SECONDS" \
            2>&1)

        # Check if we got a message
        if echo "$response" | jq -e '.Messages[0]' &>/dev/null; then
            process_sqs_message "$response"
        fi

        sleep "$POLL_INTERVAL_SECONDS"
    done
}

# ── Manual mode (for testing without SQS) ──────────────────────
if [[ "${1:-}" == "manual" ]]; then
    # Usage: ./agent.sh manual <node> <action> [mode] [reason]
    node="${2:?Usage: $0 manual <node> <action> [mode] [reason]}"
    action="${3:?Usage: $0 manual <node> <action> [mode] [reason]}"
    mode="${4:-graceful}"
    reason="${5:-manual-test}"
    request_id="manual-$(date +%s)"
    execute_action "$node" "$action" "$mode" "$reason" "$request_id"
    exit $?
fi

main
