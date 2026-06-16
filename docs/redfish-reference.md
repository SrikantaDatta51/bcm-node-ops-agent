# Redfish Power Operations Reference

Vendor-aware Redfish curl reference for NVIDIA DGX, Dell iDRAC, and HPE iLO.

---

## Vendor Identity Card

| Attribute | NVIDIA DGX (AMI BMC) | Dell iDRAC | HPE iLO |
|-----------|---------------------|------------|---------|
| BMC Product | AMI Redfish Server | iDRAC 8/9/10 | iLO 4/5/6 |
| System ID | `DGX` | `System.Embedded.1` | `1` |
| Manager ID | `BMC` | `iDRAC.Embedded.1` | `1` |
| Chassis ID | `DGX` (verify via /Chassis) | `System.Embedded.1` | `1` |
| GPU baseboard | `HGX_Baseboard_0` | N/A | N/A |
| Detect vendor | `dmidecode -s system-manufacturer` returns NVIDIA or check `/redfish/v1/` → Vendor | Returns Dell Inc. | Returns HPE |

> **Password quoting rule:** Always use **single quotes** for passwords containing `$` or `!`
> (e.g. `BMC_PASS='coupang3$!'`). Double quotes cause bash to expand `$!` as the last
> background PID, silently breaking authentication.

---

## How to Identify Your Vendor Before Connecting

```bash
# From the OS (if node is reachable via SSH)
ssh <node> "dmidecode -s system-manufacturer"
# Dell Inc. → use System.Embedded.1
# HPE       → use 1
# NVIDIA    → use DGX

# From Redfish service root (works even when OS is off — BMC always runs)
curl -sk -u admin:password https://<BMC-IP>/redfish/v1/ \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('Vendor:', d.get('Vendor'), '| Product:', d.get('Product'))"
# AMI       → DGX node
# Dell      → iDRAC
# HPE       → iLO

# Enumerate actual System IDs (always do this on an unknown node)
curl -sk -u admin:password https://<BMC-IP>/redfish/v1/Systems \
  | python3 -c "import sys,json; d=json.load(sys.stdin); [print(m['@odata.id']) for m in d['Members']]"
```

---

## NVIDIA DGX — Full Curl Reference

**BMC firmware:** AMI Redfish Server
**System IDs:** `DGX` (host), `HGX_Baseboard_0` (GPU baseboard)
**Always use `-sk`** — AMI BMC uses self-signed TLS certificates.

```bash
# Set these variables once — reuse across all commands in this section
BMC_IP="<bmc_ip>"        # DGX BMC IP
BMC_USER="coupangdgx"
BMC_PASS='<password>'     # no $ in password → double quotes are safe
SYSTEM="DGX"
CHASSIS="DGX"
MANAGER="BMC"
```

### Discover — List All Systems

```bash
# Returns the actual System IDs supported by this BMC.
# DGX returns two: DGX (host) and HGX_Baseboard_0 (GPU tray).
# Run this first on any unknown node to find the correct System ID.
curl -sk -u "${BMC_USER}:${BMC_PASS}" \
  https://${BMC_IP}/redfish/v1/Systems \
  | python3 -c "import sys,json; d=json.load(sys.stdin); [print(m['@odata.id']) for m in d['Members']]"
```

### Power State — Check if Node is On or Off

```bash
# Returns the current power state: On | Off | PoweringOn | PoweringOff
curl -sk -u "${BMC_USER}:${BMC_PASS}" \
  https://${BMC_IP}/redfish/v1/Systems/${SYSTEM} \
  | python3 -m json.tool | grep PowerState
```

### Power On — Boot from powered-off state

```bash
# Only valid when PowerState is "Off".
# BMC returns HTTP 204 (No Content) on success — empty body is expected.
curl -sk -u "${BMC_USER}:${BMC_PASS}" \
  -X POST -H "Content-Type: application/json" \
  -d '{"ResetType": "On"}' \
  https://${BMC_IP}/redfish/v1/Systems/${SYSTEM}/Actions/ComputerSystem.Reset
```

### Graceful Shutdown — Ask the OS to shut down cleanly

```bash
# Sends an ACPI power-button signal to the OS.
# The OS handles the shutdown: flushes disks, stops services, powers off.
# Requires the OS to be responsive. Use ForceOff if the OS is hung.
curl -sk -u "${BMC_USER}:${BMC_PASS}" \
  -X POST -H "Content-Type: application/json" \
  -d '{"ResetType": "GracefulShutdown"}' \
  https://${BMC_IP}/redfish/v1/Systems/${SYSTEM}/Actions/ComputerSystem.Reset
```

### Hard Power Off — Cut power immediately

```bash
# Equivalent to pulling the power cord. No OS notification whatsoever.
# Data loss is possible if filesystems are not synced.
# Use only when graceful shutdown fails or OS is completely unresponsive.
curl -sk -u "${BMC_USER}:${BMC_PASS}" \
  -X POST -H "Content-Type: application/json" \
  -d '{"ResetType": "ForceOff"}' \
  https://${BMC_IP}/redfish/v1/Systems/${SYSTEM}/Actions/ComputerSystem.Reset
```

### Graceful Reboot — Ask OS to reboot cleanly

```bash
# OS reboots via its normal shutdown + restart sequence.
# Preferred reboot method when OS is healthy and responsive.
curl -sk -u "${BMC_USER}:${BMC_PASS}" \
  -X POST -H "Content-Type: application/json" \
  -d '{"ResetType": "GracefulRestart"}' \
  https://${BMC_IP}/redfish/v1/Systems/${SYSTEM}/Actions/ComputerSystem.Reset
```

### Hard Reset — Immediate reboot without OS notification

```bash
# Forces an immediate reset. Equivalent to pressing the physical reset button.
# Use when OS is completely unresponsive and graceful reboot doesn't work.
curl -sk -u "${BMC_USER}:${BMC_PASS}" \
  -X POST -H "Content-Type: application/json" \
  -d '{"ResetType": "ForceRestart"}' \
  https://${BMC_IP}/redfish/v1/Systems/${SYSTEM}/Actions/ComputerSystem.Reset
```

---

## Dell iDRAC — Full Curl Reference

**BMC firmware:** iDRAC 8 / 9 / 10
**System ID:** `System.Embedded.1`
**Manager ID:** `iDRAC.Embedded.1`
**Always use `-sk`** — iDRAC ships with a self-signed certificate by default.

```bash
# Set these variables once — reuse across all commands in this section
BMC_IP="<bmc_ip>"           # iDRAC IP
BMC_USER="root"
BMC_PASS='<password>'        # contains $ → MUST use single quotes
SYSTEM="System.Embedded.1"
CHASSIS="System.Embedded.1"
MANAGER="iDRAC.Embedded.1"
```

### Discover — Confirm System ID

```bash
# Dell always returns System.Embedded.1 but run this to verify on
# unusual configs (blade servers, modular chassis).
curl -sk -u "${BMC_USER}:${BMC_PASS}" \
  https://${BMC_IP}/redfish/v1/Systems \
  | python3 -c "import sys,json; d=json.load(sys.stdin); [print(m['@odata.id']) for m in d['Members']]"
```

### Power State — Check if Node is On or Off

```bash
# Returns: "PowerState": "On" or "Off"
curl -sk -u "${BMC_USER}:${BMC_PASS}" \
  https://${BMC_IP}/redfish/v1/Systems/${SYSTEM} \
  | python3 -m json.tool | grep PowerState
```

### Power On — Boot from powered-off state

```bash
# Only valid when server is off.
# iDRAC returns HTTP 204 (No Content) on success — empty body is expected.
curl -sk -u "${BMC_USER}:${BMC_PASS}" \
  -X POST -H "Content-Type: application/json" \
  -d '{"ResetType": "On"}' \
  https://${BMC_IP}/redfish/v1/Systems/${SYSTEM}/Actions/ComputerSystem.Reset
```

### Graceful Shutdown — Ask the OS to shut down cleanly

```bash
# Sends ACPI signal to the OS. OS shuts down services, flushes disks, powers off.
# Preferred shutdown method when the OS is healthy and responsive.
curl -sk -u "${BMC_USER}:${BMC_PASS}" \
  -X POST -H "Content-Type: application/json" \
  -d '{"ResetType": "GracefulShutdown"}' \
  https://${BMC_IP}/redfish/v1/Systems/${SYSTEM}/Actions/ComputerSystem.Reset
```

### Hard Power Off — Cut power immediately

```bash
# Immediate power cut. No OS notification. Potential for data loss.
# Use when OS is unresponsive and graceful shutdown times out.
curl -sk -u "${BMC_USER}:${BMC_PASS}" \
  -X POST -H "Content-Type: application/json" \
  -d '{"ResetType": "ForceOff"}' \
  https://${BMC_IP}/redfish/v1/Systems/${SYSTEM}/Actions/ComputerSystem.Reset
```

### Graceful Reboot — Ask OS to reboot cleanly

```bash
# OS flushes filesystems, stops services, and reboots cleanly.
# Preferred reboot method when OS is healthy.
curl -sk -u "${BMC_USER}:${BMC_PASS}" \
  -X POST -H "Content-Type: application/json" \
  -d '{"ResetType": "GracefulRestart"}' \
  https://${BMC_IP}/redfish/v1/Systems/${SYSTEM}/Actions/ComputerSystem.Reset
```

### Hard Reset — Immediately cut and restore power (hard reboot)

```bash
# Equivalent to pressing the physical reset button on the chassis.
# No OS notification. Use when OS is hung and graceful reboot doesn't respond.
curl -sk -u "${BMC_USER}:${BMC_PASS}" \
  -X POST -H "Content-Type: application/json" \
  -d '{"ResetType": "ForceRestart"}' \
  https://${BMC_IP}/redfish/v1/Systems/${SYSTEM}/Actions/ComputerSystem.Reset
```

---

## HPE iLO — Full Curl Reference

**BMC firmware:** iLO 4 / 5 / 6
**System ID:** `1`
**Manager ID:** `1`
**Chassis ID:** `1`
**Always use `-sk`** — iLO ships with a self-signed certificate by default.

```bash
# Set these variables once — reuse across all commands in this section
BMC_IP="<bmc_ip>"
BMC_USER="pang"
BMC_PASS='<password>'        # use single quotes if password contains $ or !
SYSTEM="1"
CHASSIS="1"
MANAGER="1"
```

### Discover — Confirm System ID

```bash
# HPE almost always uses "1" but verify on blade or Synergy chassis configs.
curl -sk -u "${BMC_USER}:${BMC_PASS}" \
  https://${BMC_IP}/redfish/v1/Systems \
  | python3 -c "import sys,json; d=json.load(sys.stdin); [print(m['@odata.id']) for m in d['Members']]"
```

### Power State — Check if Node is On or Off

```bash
# Returns: "PowerState": "On" or "Off"
curl -sk -u "${BMC_USER}:${BMC_PASS}" \
  https://${BMC_IP}/redfish/v1/Systems/${SYSTEM} \
  | python3 -m json.tool | grep PowerState
```

### Power On — Boot from powered-off state

```bash
# Note: iLO returns HTTP 200 with a task response body on success
# (unlike DGX/iDRAC which return HTTP 204 with empty body).
curl -sk -u "${BMC_USER}:${BMC_PASS}" \
  -X POST -H "Content-Type: application/json" \
  -d '{"ResetType": "On"}' \
  https://${BMC_IP}/redfish/v1/Systems/${SYSTEM}/Actions/ComputerSystem.Reset
```

### Graceful Shutdown — Ask the OS to shut down cleanly

```bash
# iLO sends an ACPI signal to the OS.
# The OS handles the full shutdown sequence before powering off.
curl -sk -u "${BMC_USER}:${BMC_PASS}" \
  -X POST -H "Content-Type: application/json" \
  -d '{"ResetType": "GracefulShutdown"}' \
  https://${BMC_IP}/redfish/v1/Systems/${SYSTEM}/Actions/ComputerSystem.Reset
```

### Hard Power Off — Cut power immediately

```bash
# Immediate power cut with no OS notification. Potential for data loss.
# Use only when OS is unresponsive.
curl -sk -u "${BMC_USER}:${BMC_PASS}" \
  -X POST -H "Content-Type: application/json" \
  -d '{"ResetType": "ForceOff"}' \
  https://${BMC_IP}/redfish/v1/Systems/${SYSTEM}/Actions/ComputerSystem.Reset
```

### Graceful Reboot — Ask OS to reboot cleanly

```bash
# OS reboots via its normal shutdown + restart sequence.
# Preferred reboot method whenever the OS is healthy and responsive.
curl -sk -u "${BMC_USER}:${BMC_PASS}" \
  -X POST -H "Content-Type: application/json" \
  -d '{"ResetType": "GracefulRestart"}' \
  https://${BMC_IP}/redfish/v1/Systems/${SYSTEM}/Actions/ComputerSystem.Reset
```

### Hard Reset — Immediately cut and restore power (hard reboot)

```bash
# Forces an immediate reset. Equivalent to pressing the physical reset button.
# Use when OS is completely unresponsive and graceful reboot doesn't work.
curl -sk -u "${BMC_USER}:${BMC_PASS}" \
  -X POST -H "Content-Type: application/json" \
  -d '{"ResetType": "ForceRestart"}' \
  https://${BMC_IP}/redfish/v1/Systems/${SYSTEM}/Actions/ComputerSystem.Reset
```

---

## Vendor Comparison — Operations at a Glance

| Operation | DGX (AMI BMC) | Dell iDRAC | HPE iLO |
|-----------|--------------|------------|---------|
| System ID | `DGX` | `System.Embedded.1` | `1` |
| Manager ID | `BMC` | `iDRAC.Embedded.1` | `1` |
| Chassis ID | `DGX` | `System.Embedded.1` | `1` |
| Power state | `GET /Systems/DGX` | `GET /Systems/System.Embedded.1` | `GET /Systems/1` |
| Power on | `{"ResetType":"On"}` | `{"ResetType":"On"}` | `{"ResetType":"On"}` |
| Graceful shutdown | `{"ResetType":"GracefulShutdown"}` | `{"ResetType":"GracefulShutdown"}` | `{"ResetType":"GracefulShutdown"}` |
| Hard power off | `{"ResetType":"ForceOff"}` | `{"ResetType":"ForceOff"}` | `{"ResetType":"ForceOff"}` |
| Graceful reboot | `{"ResetType":"GracefulRestart"}` | `{"ResetType":"GracefulRestart"}` | `{"ResetType":"GracefulRestart"}` |
| Hard reset | `{"ResetType":"ForceRestart"}` | `{"ResetType":"ForceRestart"}` | `{"ResetType":"ForceRestart"}` |

> **Tip:** Always start with `GET /redfish/v1/Systems/` to discover the exact System ID before running any power commands.
