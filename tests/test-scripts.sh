#!/usr/bin/env bash
# test-scripts.sh — Basic validation tests for agent scripts
# Run: bash tests/test-scripts.sh
set -euo pipefail

PASS=0 FAIL=0
DIR="$(cd "$(dirname "$0")/.." && pwd)"

pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

echo "=== BCM Node Ops Agent — Script Tests ==="
echo ""

# ── common.sh sourcing ──────────────────────────────────────────
echo "--- common.sh ---"

# Test: validate_node_name accepts valid names
(
    export REDFISH_PASSWORD=test
    export NODE_INVENTORY_PATH="$DIR/config/nodes.yaml"
    source "$DIR/scripts/common.sh"
    validate_node_name "dgx-b200-017"
) && pass "validate_node_name accepts dgx-b200-017" || fail "validate_node_name rejects dgx-b200-017"

(
    export REDFISH_PASSWORD=test
    export NODE_INVENTORY_PATH="$DIR/config/nodes.yaml"
    source "$DIR/scripts/common.sh"
    validate_node_name "cpu-r660-004"
) && pass "validate_node_name accepts cpu-r660-004" || fail "validate_node_name rejects cpu-r660-004"

# Test: validate_node_name rejects bad names
(
    export REDFISH_PASSWORD=test
    export NODE_INVENTORY_PATH="$DIR/config/nodes.yaml"
    source "$DIR/scripts/common.sh"
    validate_node_name "evil;rm -rf /" 2>/dev/null
) && fail "validate_node_name accepts injection" || pass "validate_node_name rejects injection"

(
    export REDFISH_PASSWORD=test
    export NODE_INVENTORY_PATH="$DIR/config/nodes.yaml"
    source "$DIR/scripts/common.sh"
    validate_node_name 'node$(whoami)' 2>/dev/null
) && fail "validate_node_name accepts command sub" || pass "validate_node_name rejects command substitution"

echo ""
echo "--- inventory lookup ---"

# Test: lookup_bmc_host finds known nodes
(
    export REDFISH_PASSWORD=test
    export NODE_INVENTORY_PATH="$DIR/config/nodes.yaml"
    source "$DIR/scripts/common.sh"
    result=$(lookup_bmc_host "dgx-b200-017")
    [[ "$result" == "https://10.10.20.17" ]]
) && pass "lookup_bmc_host finds dgx-b200-017 → https://10.10.20.17" || fail "lookup_bmc_host dgx-b200-017"

(
    export REDFISH_PASSWORD=test
    export NODE_INVENTORY_PATH="$DIR/config/nodes.yaml"
    source "$DIR/scripts/common.sh"
    result=$(lookup_bmc_host "cpu-r660-004")
    [[ "$result" == "https://10.10.30.4" ]]
) && pass "lookup_bmc_host finds cpu-r660-004 → https://10.10.30.4" || fail "lookup_bmc_host cpu-r660-004"

# Test: lookup_bmc_host fails for unknown nodes
(
    export REDFISH_PASSWORD=test
    export NODE_INVENTORY_PATH="$DIR/config/nodes.yaml"
    source "$DIR/scripts/common.sh"
    lookup_bmc_host "nonexistent-999" 2>/dev/null
) && fail "lookup_bmc_host accepts unknown node" || pass "lookup_bmc_host rejects unknown node"

# Test: lookup_node_type
(
    export REDFISH_PASSWORD=test
    export NODE_INVENTORY_PATH="$DIR/config/nodes.yaml"
    source "$DIR/scripts/common.sh"
    result=$(lookup_node_type "dgx-b200-017")
    [[ "$result" == "gpu" ]]
) && pass "lookup_node_type dgx-b200-017 → gpu" || fail "lookup_node_type dgx-b200-017"

(
    export REDFISH_PASSWORD=test
    export NODE_INVENTORY_PATH="$DIR/config/nodes.yaml"
    source "$DIR/scripts/common.sh"
    result=$(lookup_node_type "cpu-r660-004")
    [[ "$result" == "cpu" ]]
) && pass "lookup_node_type cpu-r660-004 → cpu" || fail "lookup_node_type cpu-r660-004"

echo ""
echo "--- action allowlist ---"

# Test: is_action_allowed
(
    export REDFISH_PASSWORD=test
    export NODE_INVENTORY_PATH="$DIR/config/nodes.yaml"
    source "$DIR/scripts/common.sh"
    is_action_allowed "dgx-b200-017" "reboot"
) && pass "reboot allowed for dgx-b200-017" || fail "reboot should be allowed for dgx-b200-017"

(
    export REDFISH_PASSWORD=test
    export NODE_INVENTORY_PATH="$DIR/config/nodes.yaml"
    source "$DIR/scripts/common.sh"
    is_action_allowed "cpu-r660-005" "power_off" 2>/dev/null
) && fail "power_off allowed for cpu-r660-005 (should not be)" || pass "power_off rejected for cpu-r660-005 (only status+reboot)"

(
    export REDFISH_PASSWORD=test
    export NODE_INVENTORY_PATH="$DIR/config/nodes.yaml"
    source "$DIR/scripts/common.sh"
    is_action_allowed "cpu-r660-005" "status"
) && pass "status allowed for cpu-r660-005" || fail "status should be allowed for cpu-r660-005"

echo ""
echo "--- audit log ---"

# Test: emit_audit writes to file
(
    export REDFISH_PASSWORD=test
    export NODE_INVENTORY_PATH="$DIR/config/nodes.yaml"
    export AUDIT_LOG_DIR=$(mktemp -d)
    source "$DIR/scripts/common.sh"
    emit_audit "test-node" "reboot" "SUCCESS" "GracefulRestart" "test message" "test reason" > /dev/null
    [[ -f "$AUDIT_LOG_DIR/audit.jsonl" ]]
    grep -q '"node":"test-node"' "$AUDIT_LOG_DIR/audit.jsonl"
    rm -rf "$AUDIT_LOG_DIR"
) && pass "emit_audit writes structured JSON to audit.jsonl" || fail "emit_audit"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
