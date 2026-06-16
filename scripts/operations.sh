#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════╗
# ║  operations.sh — THE FILE YOU EDIT                            ║
# ║                                                               ║
# ║  This file contains the actual commands for each operation.   ║
# ║  Edit the functions below to match your environment.          ║
# ║  The agent calls these functions — you control what they do.  ║
# ╚═══════════════════════════════════════════════════════════════╝
#
# Each function receives:
#   $1 = node name       (e.g. dgx-b200-017)
#   $2 = BMC host        (e.g. https://10.10.20.17)
#   $3 = mode            (e.g. graceful, force — where applicable)
#   $4 = reason          (e.g. "firmware upgrade")
#
# Each function must:
#   - Exit 0 on success, non-zero on failure
#   - Print a one-line result message to stdout
#
# Environment available:
#   REDFISH_USER, REDFISH_PASSWORD, REDFISH_TLS_VERIFY, REDFISH_TIMEOUT

CURL_BASE=(curl -s -S --max-time "${REDFISH_TIMEOUT:-30}" -u "${REDFISH_USER}:${REDFISH_PASSWORD}")
[[ "${REDFISH_TLS_VERIFY:-false}" == "false" ]] && CURL_BASE+=(-k)

# ────────────────────────────────────────────────────────────────
# REBOOT — Edit the Redfish ResetType if your hardware differs
# ────────────────────────────────────────────────────────────────
do_reboot() {
    local node="$1" bmc="$2" mode="${3:-graceful}" reason="$4"
    local reset_type="GracefulRestart"
    [[ "$mode" == "force" ]] && reset_type="ForceRestart"

    local http_code
    http_code=$("${CURL_BASE[@]}" -o /dev/null -w "%{http_code}" \
        -X POST -H "Content-Type: application/json" \
        -d "{\"ResetType\":\"${reset_type}\"}" \
        "${bmc}/redfish/v1/Systems/1/Actions/ComputerSystem.Reset")

    if [[ "$http_code" =~ ^(200|204)$ ]]; then
        echo "Redfish ${reset_type} accepted (HTTP ${http_code})"
        return 0
    else
        echo "Redfish ${reset_type} failed (HTTP ${http_code})"
        return 1
    fi
}

# ────────────────────────────────────────────────────────────────
# POWER ON
# ────────────────────────────────────────────────────────────────
do_power_on() {
    local node="$1" bmc="$2" mode="$3" reason="$4"
    local reset_type="On"

    local http_code
    http_code=$("${CURL_BASE[@]}" -o /dev/null -w "%{http_code}" \
        -X POST -H "Content-Type: application/json" \
        -d "{\"ResetType\":\"${reset_type}\"}" \
        "${bmc}/redfish/v1/Systems/1/Actions/ComputerSystem.Reset")

    if [[ "$http_code" =~ ^(200|204)$ ]]; then
        echo "Redfish ${reset_type} accepted (HTTP ${http_code})"
        return 0
    else
        echo "Redfish ${reset_type} failed (HTTP ${http_code})"
        return 1
    fi
}

# ────────────────────────────────────────────────────────────────
# POWER OFF
# ────────────────────────────────────────────────────────────────
do_power_off() {
    local node="$1" bmc="$2" mode="${3:-graceful}" reason="$4"
    local reset_type="GracefulShutdown"
    [[ "$mode" == "force" ]] && reset_type="ForceOff"

    local http_code
    http_code=$("${CURL_BASE[@]}" -o /dev/null -w "%{http_code}" \
        -X POST -H "Content-Type: application/json" \
        -d "{\"ResetType\":\"${reset_type}\"}" \
        "${bmc}/redfish/v1/Systems/1/Actions/ComputerSystem.Reset")

    if [[ "$http_code" =~ ^(200|204)$ ]]; then
        echo "Redfish ${reset_type} accepted (HTTP ${http_code})"
        return 0
    else
        echo "Redfish ${reset_type} failed (HTTP ${http_code})"
        return 1
    fi
}

# ────────────────────────────────────────────────────────────────
# POWER CYCLE
# ────────────────────────────────────────────────────────────────
do_power_cycle() {
    local node="$1" bmc="$2" mode="$3" reason="$4"
    local reset_type="PowerCycle"

    local http_code
    http_code=$("${CURL_BASE[@]}" -o /dev/null -w "%{http_code}" \
        -X POST -H "Content-Type: application/json" \
        -d "{\"ResetType\":\"${reset_type}\"}" \
        "${bmc}/redfish/v1/Systems/1/Actions/ComputerSystem.Reset")

    if [[ "$http_code" =~ ^(200|204)$ ]]; then
        echo "Redfish ${reset_type} accepted (HTTP ${http_code})"
        return 0
    else
        echo "Redfish ${reset_type} failed (HTTP ${http_code})"
        return 1
    fi
}

# ────────────────────────────────────────────────────────────────
# STATUS CHECK — via BCM cmsh
# ────────────────────────────────────────────────────────────────
do_status() {
    local node="$1" bmc="$2" mode="$3" reason="$4"

    if command -v cmsh &>/dev/null; then
        local output
        output=$(cmsh -c "device use ${node}; status" 2>&1) || true

        if echo "$output" | grep -qi "UP"; then
            echo "bcm_status=UP,power=On,reachable=true"
        elif echo "$output" | grep -qi "DOWN\|CLOSED"; then
            echo "bcm_status=DOWN,power=Off,reachable=false"
        else
            echo "bcm_status=UNKNOWN,raw=${output}"
        fi
    else
        echo "bcm_status=UNKNOWN,cmsh_not_available=true"
    fi
    return 0
}

# ────────────────────────────────────────────────────────────────
# POST-ACTION STATUS POLL — called after reboot/power ops
# Waits for node to come back up. Edit timeouts as needed.
# ────────────────────────────────────────────────────────────────
poll_status_after_action() {
    local node="$1" action="$2" max_wait="${3:-300}" interval="${4:-15}"
    local elapsed=0

    while (( elapsed < max_wait )); do
        sleep "$interval"
        elapsed=$((elapsed + interval))

        local result
        result=$(do_status "$node" "" "" "post-${action}-poll")

        if [[ "$action" == "power_off" ]]; then
            # For power-off, success = node is DOWN
            if echo "$result" | grep -q "bcm_status=DOWN"; then
                echo "Node $node confirmed DOWN after ${elapsed}s"
                return 0
            fi
        else
            # For reboot/power-on/power-cycle, success = node is UP
            if echo "$result" | grep -q "bcm_status=UP"; then
                echo "Node $node confirmed UP after ${elapsed}s"
                return 0
            fi
        fi
    done

    echo "Node $node did not reach expected state after ${max_wait}s"
    return 1
}
