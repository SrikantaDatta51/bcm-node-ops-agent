#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════╗
# ║  operations.sh — THE FILE YOU EDIT                            ║
# ║                                                               ║
# ║  Vendor-aware Redfish power operations.                       ║
# ║  Supports: NVIDIA DGX (AMI BMC), Dell iDRAC, HPE iLO         ║
# ║                                                               ║
# ║  System ID is resolved from vendor field in nodes.yaml:       ║
# ║    dgx   → /redfish/v1/Systems/DGX/                          ║
# ║    idrac → /redfish/v1/Systems/System.Embedded.1/             ║
# ║    ilo   → /redfish/v1/Systems/1/                             ║
# ╚═══════════════════════════════════════════════════════════════╝
#
# Each function receives:
#   $1 = node name       (e.g. dgx-b200-017)
#   $2 = BMC host        (e.g. https://10.10.20.17)
#   $3 = mode            (e.g. graceful, force — where applicable)
#   $4 = reason          (e.g. "firmware upgrade")
#   $5 = system_id       (e.g. DGX, System.Embedded.1, 1)
#
# Each function must:
#   - Exit 0 on success, non-zero on failure
#   - Print a one-line result message to stdout
#
# Environment available (set in agent.conf):
#   Per-vendor: REDFISH_USER_DGX, REDFISH_PASSWORD_DGX, etc.
#   Fallback:   REDFISH_USER, REDFISH_PASSWORD
#   Common:     REDFISH_TLS_VERIFY, REDFISH_TIMEOUT

# ── Vendor → System ID mapping ─────────────────────────────────
resolve_system_id() {
    local vendor="${1:-ilo}"
    case "$vendor" in
        dgx)   echo "DGX" ;;
        idrac) echo "System.Embedded.1" ;;
        ilo)   echo "1" ;;
        *)     echo "1" ;;
    esac
}

# ── Credential resolution ───────────────────────────────────────
# Priority: per-node (nodes.yaml) → per-vendor (agent.conf) → global fallback
# Per-node creds are exported by agent.sh as _NODE_CRED_USER / _NODE_CRED_PASS
resolve_creds() {
    local vendor="${1:-}"

    # 1. Per-node override (bmc_user / bmc_password in nodes.yaml)
    if [[ -n "${_NODE_CRED_USER:-}" && -n "${_NODE_CRED_PASS:-}" ]]; then
        _RF_USER="$_NODE_CRED_USER"
        _RF_PASS="$_NODE_CRED_PASS"
        return
    fi

    # 2. Per-vendor (REDFISH_USER_DGX, etc. in agent.conf)
    # 3. Global fallback (REDFISH_USER / REDFISH_PASSWORD)
    case "$vendor" in
        dgx)
            _RF_USER="${REDFISH_USER_DGX:-${REDFISH_USER:-admin}}"
            _RF_PASS="${REDFISH_PASSWORD_DGX:-${REDFISH_PASSWORD:-changeme}}"
            ;;
        idrac)
            _RF_USER="${REDFISH_USER_IDRAC:-${REDFISH_USER:-admin}}"
            _RF_PASS="${REDFISH_PASSWORD_IDRAC:-${REDFISH_PASSWORD:-changeme}}"
            ;;
        ilo)
            _RF_USER="${REDFISH_USER_ILO:-${REDFISH_USER:-admin}}"
            _RF_PASS="${REDFISH_PASSWORD_ILO:-${REDFISH_PASSWORD:-changeme}}"
            ;;
        *)
            _RF_USER="${REDFISH_USER:-admin}"
            _RF_PASS="${REDFISH_PASSWORD:-changeme}"
            ;;
    esac
}

# ── Build curl command with resolved credentials ───────────────
# Call resolve_creds() first, then use build_curl() for the command.
build_curl() {
    local cmd=(curl -s -S --max-time "${REDFISH_TIMEOUT:-30}" -u "${_RF_USER}:${_RF_PASS}")
    [[ "${REDFISH_TLS_VERIFY:-false}" == "false" ]] && cmd+=(-k)
    echo "${cmd[@]}"
}

# ────────────────────────────────────────────────────────────────
# REBOOT
# ────────────────────────────────────────────────────────────────
do_reboot() {
    local node="$1" bmc="$2" mode="${3:-graceful}" reason="$4" system_id="${5:-1}" vendor="${6:-}"
    local reset_type="GracefulRestart"
    [[ "$mode" == "force" ]] && reset_type="ForceRestart"

    resolve_creds "$vendor"
    local CURL_CMD=(curl -s -S --max-time "${REDFISH_TIMEOUT:-30}" -u "${_RF_USER}:${_RF_PASS}")
    [[ "${REDFISH_TLS_VERIFY:-false}" == "false" ]] && CURL_CMD+=(-k)

    local http_code
    http_code=$("${CURL_CMD[@]}" -o /dev/null -w "%{http_code}" \
        -X POST -H "Content-Type: application/json" \
        -d "{\"ResetType\":\"${reset_type}\"}" \
        "${bmc}/redfish/v1/Systems/${system_id}/Actions/ComputerSystem.Reset")

    if [[ "$http_code" =~ ^(200|204)$ ]]; then
        echo "Redfish ${reset_type} accepted (HTTP ${http_code}) [system=${system_id}, user=${_RF_USER}]"
        return 0
    else
        echo "Redfish ${reset_type} failed (HTTP ${http_code}) [system=${system_id}, user=${_RF_USER}]"
        return 1
    fi
}

# ────────────────────────────────────────────────────────────────
# POWER ON
# ────────────────────────────────────────────────────────────────
do_power_on() {
    local node="$1" bmc="$2" mode="$3" reason="$4" system_id="${5:-1}" vendor="${6:-}"
    local reset_type="On"

    resolve_creds "$vendor"
    local CURL_CMD=(curl -s -S --max-time "${REDFISH_TIMEOUT:-30}" -u "${_RF_USER}:${_RF_PASS}")
    [[ "${REDFISH_TLS_VERIFY:-false}" == "false" ]] && CURL_CMD+=(-k)

    local http_code
    http_code=$("${CURL_CMD[@]}" -o /dev/null -w "%{http_code}" \
        -X POST -H "Content-Type: application/json" \
        -d "{\"ResetType\":\"${reset_type}\"}" \
        "${bmc}/redfish/v1/Systems/${system_id}/Actions/ComputerSystem.Reset")

    if [[ "$http_code" =~ ^(200|204)$ ]]; then
        echo "Redfish ${reset_type} accepted (HTTP ${http_code}) [system=${system_id}, user=${_RF_USER}]"
        return 0
    else
        echo "Redfish ${reset_type} failed (HTTP ${http_code}) [system=${system_id}, user=${_RF_USER}]"
        return 1
    fi
}

# ────────────────────────────────────────────────────────────────
# POWER OFF
# ────────────────────────────────────────────────────────────────
do_power_off() {
    local node="$1" bmc="$2" mode="${3:-graceful}" reason="$4" system_id="${5:-1}" vendor="${6:-}"
    local reset_type="GracefulShutdown"
    [[ "$mode" == "force" ]] && reset_type="ForceOff"

    resolve_creds "$vendor"
    local CURL_CMD=(curl -s -S --max-time "${REDFISH_TIMEOUT:-30}" -u "${_RF_USER}:${_RF_PASS}")
    [[ "${REDFISH_TLS_VERIFY:-false}" == "false" ]] && CURL_CMD+=(-k)

    local http_code
    http_code=$("${CURL_CMD[@]}" -o /dev/null -w "%{http_code}" \
        -X POST -H "Content-Type: application/json" \
        -d "{\"ResetType\":\"${reset_type}\"}" \
        "${bmc}/redfish/v1/Systems/${system_id}/Actions/ComputerSystem.Reset")

    if [[ "$http_code" =~ ^(200|204)$ ]]; then
        echo "Redfish ${reset_type} accepted (HTTP ${http_code}) [system=${system_id}, user=${_RF_USER}]"
        return 0
    else
        echo "Redfish ${reset_type} failed (HTTP ${http_code}) [system=${system_id}, user=${_RF_USER}]"
        return 1
    fi
}

# ────────────────────────────────────────────────────────────────
# POWER CYCLE
# ────────────────────────────────────────────────────────────────
do_power_cycle() {
    local node="$1" bmc="$2" mode="$3" reason="$4" system_id="${5:-1}" vendor="${6:-}"
    local reset_type="PowerCycle"

    resolve_creds "$vendor"
    local CURL_CMD=(curl -s -S --max-time "${REDFISH_TIMEOUT:-30}" -u "${_RF_USER}:${_RF_PASS}")
    [[ "${REDFISH_TLS_VERIFY:-false}" == "false" ]] && CURL_CMD+=(-k)

    local http_code
    http_code=$("${CURL_CMD[@]}" -o /dev/null -w "%{http_code}" \
        -X POST -H "Content-Type: application/json" \
        -d "{\"ResetType\":\"${reset_type}\"}" \
        "${bmc}/redfish/v1/Systems/${system_id}/Actions/ComputerSystem.Reset")

    if [[ "$http_code" =~ ^(200|204)$ ]]; then
        echo "Redfish ${reset_type} accepted (HTTP ${http_code}) [system=${system_id}, user=${_RF_USER}]"
        return 0
    else
        echo "Redfish ${reset_type} failed (HTTP ${http_code}) [system=${system_id}, user=${_RF_USER}]"
        return 1
    fi
}

# ────────────────────────────────────────────────────────────────
# STATUS CHECK — via Redfish + BCM cmsh
# ────────────────────────────────────────────────────────────────
do_status() {
    local node="$1" bmc="$2" mode="$3" reason="$4" system_id="${5:-1}" vendor="${6:-}"

    # First try Redfish power state query (works even when OS is down)
    local power_state="Unknown"
    if [[ -n "$bmc" ]]; then
        resolve_creds "$vendor"
        local CURL_CMD=(curl -s -S --max-time "${REDFISH_TIMEOUT:-30}" -u "${_RF_USER}:${_RF_PASS}")
        [[ "${REDFISH_TLS_VERIFY:-false}" == "false" ]] && CURL_CMD+=(-k)

        power_state=$("${CURL_CMD[@]}" \
            "${bmc}/redfish/v1/Systems/${system_id}" 2>/dev/null \
            | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('PowerState','Unknown'))" 2>/dev/null) || power_state="Unknown"
    fi

    # Then try cmsh for BCM-level status
    if command -v cmsh &>/dev/null; then
        local output
        output=$(cmsh -c "device use ${node}; status" 2>&1) || true

        if echo "$output" | grep -qi "UP"; then
            echo "bcm_status=UP,power=${power_state},reachable=true,system_id=${system_id},user=${_RF_USER:-n/a}"
        elif echo "$output" | grep -qi "DOWN\|CLOSED"; then
            echo "bcm_status=DOWN,power=${power_state},reachable=false,system_id=${system_id},user=${_RF_USER:-n/a}"
        else
            echo "bcm_status=UNKNOWN,power=${power_state},raw=${output},system_id=${system_id}"
        fi
    else
        echo "bcm_status=UNKNOWN,power=${power_state},cmsh_not_available=true,system_id=${system_id}"
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
        result=$(do_status "$node" "" "" "post-${action}-poll" "")

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
