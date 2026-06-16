#!/usr/bin/env bash
# setup.sh — Pull images and bootstrap BCM Node Ops Agent on containerd
# Run once: sudo bash scripts/setup.sh
set -euo pipefail

KESTRA_IMAGE="docker.io/kestra/kestra:latest"
POSTGRES_IMAGE="docker.io/library/postgres:16-alpine"
NAMESPACE="bcm-node-ops"

echo "=== BCM Node Ops Agent — Setup ==="
echo ""

# ── Pull images via containerd ──────────────────────────────────
echo "[1/5] Pulling container images..."
ctr image pull "$KESTRA_IMAGE"
ctr image pull "$POSTGRES_IMAGE"

# ── Create directories ──────────────────────────────────────────
echo "[2/5] Creating directories..."
mkdir -p /opt/bcm-node-ops/{config,scripts,logs}
mkdir -p /var/lib/bcm-node-ops/{kestra-data,postgres-data}
mkdir -p /var/log/bcm-node-ops

# ── Copy files ──────────────────────────────────────────────────
echo "[3/5] Installing scripts and config..."
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

cp "$SCRIPT_DIR"/scripts/*.sh /opt/bcm-node-ops/scripts/
chmod +x /opt/bcm-node-ops/scripts/*.sh

cp "$SCRIPT_DIR"/config/nodes.yaml /opt/bcm-node-ops/config/
cp "$SCRIPT_DIR"/kestra/application.yaml /opt/bcm-node-ops/config/kestra-application.yaml

if [[ -f "$SCRIPT_DIR/.env" ]]; then
    cp "$SCRIPT_DIR/.env" /opt/bcm-node-ops/.env
else
    cp "$SCRIPT_DIR/.env.example" /opt/bcm-node-ops/.env
    echo "  ⚠ Copied .env.example — edit /opt/bcm-node-ops/.env with real credentials"
fi

# ── Install systemd units ───────────────────────────────────────
echo "[4/5] Installing systemd units..."
cp "$SCRIPT_DIR"/systemd/*.service /etc/systemd/system/
systemctl daemon-reload

# ── Enable services ─────────────────────────────────────────────
echo "[5/5] Enabling services..."
systemctl enable bcm-node-ops-db.service
systemctl enable bcm-node-ops-kestra.service

echo ""
echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo "  1. Edit /opt/bcm-node-ops/.env with real Redfish credentials"
echo "  2. Edit /opt/bcm-node-ops/config/nodes.yaml with your nodes"
echo "  3. Start:  sudo systemctl start bcm-node-ops-db"
echo "             sudo systemctl start bcm-node-ops-kestra"
echo "  4. Kestra UI: http://$(hostname):8080"
echo ""
