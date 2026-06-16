#!/usr/bin/env bash
# test-agent.sh — Validate agent scripts
set -euo pipefail

PASS=0 FAIL=0
DIR="$(cd "$(dirname "$0")/.." && pwd)"

pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

echo "=== BCM Node Ops Agent — Tests ==="

# Set env for testing
export REDFISH_USER=test REDFISH_PASSWORD=test REDFISH_TIMEOUT=5
export NODE_INVENTORY="$DIR/config/nodes.yaml"
export AUDIT_LOG=$(mktemp)
export LOG_DIR=$(mktemp -d)

# Source operations
source "$DIR/scripts/operations.sh"

# Re-implement the inventory/validation functions here (same as agent.sh)
log()  { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >&2; }
audit() {
    local record="{\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"node\":\"$1\",\"action\":\"$2\",\"status\":\"$3\",\"message\":\"$4\",\"request_id\":\"$5\",\"reason\":\"$6\"}"
    echo "$record" >> "$AUDIT_LOG"
    echo "$record"
}
lookup_bmc() {
    local node="$1" in_node=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]{2}${node}: ]]; then in_node=true; continue; fi
        if $in_node; then
            if [[ "$line" =~ bmc_host:[[:space:]]*(.+) ]]; then
                local h="${BASH_REMATCH[1]}"; h="${h%\"}"; h="${h#\"}"; h="${h%\'}"; h="${h#\'}"
                echo "$h"; return 0
            fi
            [[ "$line" =~ ^[[:space:]]{2}[a-zA-Z] ]] && ! [[ "$line" =~ ^[[:space:]]{4} ]] && break
        fi
    done < "$NODE_INVENTORY"
    return 1
}
is_allowed() { grep -A5 "^  ${1}:" "$NODE_INVENTORY" | grep -q "allowed:.*${2}"; }
validate_node() { [[ "$1" =~ ^[a-zA-Z0-9._-]+$ ]]; }

echo ""
echo "--- node validation ---"

(validate_node "dgx-b200-017") 2>/dev/null \
    && pass "accepts dgx-b200-017" || fail "rejects dgx-b200-017"
(validate_node "cpu-r660-004") 2>/dev/null \
    && pass "accepts cpu-r660-004" || fail "rejects cpu-r660-004"
(validate_node "evil;rm -rf /") 2>/dev/null \
    && fail "accepts injection" || pass "rejects shell injection"
(validate_node 'node$(whoami)') 2>/dev/null \
    && fail "accepts command sub" || pass "rejects command substitution"

echo ""
echo "--- inventory lookup ---"

result=$(lookup_bmc "dgx-b200-017" 2>/dev/null) && [[ "$result" == "https://10.10.20.17" ]] \
    && pass "dgx-b200-017 → https://10.10.20.17" || fail "dgx-b200-017 lookup"
result=$(lookup_bmc "cpu-r660-004" 2>/dev/null) && [[ "$result" == "https://10.10.30.4" ]] \
    && pass "cpu-r660-004 → https://10.10.30.4" || fail "cpu-r660-004 lookup"
(lookup_bmc "nonexistent-999" 2>/dev/null) \
    && fail "accepts unknown node" || pass "rejects unknown node"

echo ""
echo "--- action allowlist ---"

(is_allowed "dgx-b200-017" "reboot" 2>/dev/null) \
    && pass "reboot allowed for dgx-b200-017" || fail "reboot denied for dgx-b200-017"
(is_allowed "cpu-r660-005" "power_off" 2>/dev/null) \
    && fail "power_off allowed for cpu-r660-005" || pass "power_off denied for cpu-r660-005"
(is_allowed "cpu-r660-005" "status" 2>/dev/null) \
    && pass "status allowed for cpu-r660-005" || fail "status denied for cpu-r660-005"

echo ""
echo "--- audit logging ---"

audit "test-node" "reboot" "SUCCESS" "test msg" "req-001" "test" > /dev/null
grep -q '"node":"test-node"' "$AUDIT_LOG" \
    && pass "audit writes JSON" || fail "audit write"
grep -q '"request_id":"req-001"' "$AUDIT_LOG" \
    && pass "audit includes request_id" || fail "audit request_id"

echo ""
echo "--- SQS message format ---"

SAMPLE='{"Messages":[{"Body":"{\"node\":\"dgx-b200-017\",\"action\":\"reboot\",\"mode\":\"graceful\",\"reason\":\"test\",\"request_id\":\"sqs-001\"}","ReceiptHandle":"abc123"}]}'
parsed_node=$(echo "$SAMPLE" | jq -r '.Messages[0].Body' | jq -r '.node')
parsed_action=$(echo "$SAMPLE" | jq -r '.Messages[0].Body' | jq -r '.action')
[[ "$parsed_node" == "dgx-b200-017" ]] && pass "SQS body → node parsed" || fail "SQS node parse"
[[ "$parsed_action" == "reboot" ]] && pass "SQS body → action parsed" || fail "SQS action parse"

# Cleanup
rm -f "$AUDIT_LOG"
rm -rf "$LOG_DIR"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
