#!/usr/bin/env bash
# install.sh — One-time setup for BCM Node Ops Agent
# Run: sudo bash scripts/install.sh
set -euo pipefail

INSTALL_DIR=/opt/bcm-node-ops

echo "=== BCM Node Ops Agent — Install ==="
echo ""

# ── 1. Install dependencies ────────────────────────────────────
echo "[1/5] Installing dependencies (jq, aws-cli)..."

# jq
if ! command -v jq &>/dev/null; then
    if command -v yum &>/dev/null; then
        yum install -y jq
    elif command -v apt-get &>/dev/null; then
        apt-get update && apt-get install -y jq
    else
        echo "  Installing jq from GitHub..."
        curl -sL https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64 -o /usr/local/bin/jq
        chmod +x /usr/local/bin/jq
    fi
fi
echo "  ✓ jq $(jq --version)"

# AWS CLI v2
if ! command -v aws &>/dev/null; then
    echo "  Installing AWS CLI v2..."
    cd /tmp
    curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
    unzip -qo awscliv2.zip
    ./aws/install --update
    rm -rf awscliv2.zip aws/
fi
echo "  ✓ aws $(aws --version 2>&1 | head -1)"

# ── 2. Create directories ──────────────────────────────────────
echo "[2/5] Creating directories..."
mkdir -p "$INSTALL_DIR"/{scripts,config}
mkdir -p /var/log/bcm-node-ops

# ── 3. Copy files ──────────────────────────────────────────────
echo "[3/5] Installing files to $INSTALL_DIR..."
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

cp "$REPO_DIR"/scripts/agent.sh       "$INSTALL_DIR/scripts/"
cp "$REPO_DIR"/scripts/operations.sh  "$INSTALL_DIR/scripts/"
chmod +x "$INSTALL_DIR"/scripts/*.sh

cp "$REPO_DIR"/config/nodes.yaml      "$INSTALL_DIR/config/"

if [[ -f "$REPO_DIR/config/agent.conf" ]]; then
    if [[ -f "$INSTALL_DIR/config/agent.conf" ]]; then
        echo "  ⚠ agent.conf already exists — not overwriting. New version saved as agent.conf.new"
        cp "$REPO_DIR"/config/agent.conf "$INSTALL_DIR/config/agent.conf.new"
    else
        cp "$REPO_DIR"/config/agent.conf "$INSTALL_DIR/config/"
    fi
fi

# ── 4. Install systemd unit ────────────────────────────────────
echo "[4/5] Installing systemd service..."
cp "$REPO_DIR"/systemd/bcm-node-ops-agent.service /etc/systemd/system/
systemctl daemon-reload

# ── 5. Enable (but don't start) ────────────────────────────────
echo "[5/5] Enabling service..."
systemctl enable bcm-node-ops-agent.service

echo ""
echo "=== Install complete ==="
echo ""
echo "Next steps:"
echo "  1. Edit $INSTALL_DIR/config/agent.conf"
echo "     - Set REDFISH_USER / REDFISH_PASSWORD"
echo "     - Set SQS_QUEUE_URL / SNS_TOPIC_ARN (when connectivity is ready)"
echo ""
echo "  2. Edit $INSTALL_DIR/config/nodes.yaml"
echo "     - Add your GPU/CPU nodes with BMC IPs"
echo ""
echo "  3. (Optional) Edit $INSTALL_DIR/scripts/operations.sh"
echo "     - Customize Redfish commands if needed"
echo ""
echo "  4. Test manually:"
echo "     $INSTALL_DIR/scripts/agent.sh manual dgx-b200-017 status"
echo "     $INSTALL_DIR/scripts/agent.sh manual dgx-b200-017 reboot graceful \"test\""
echo ""
echo "  5. Start the agent:"
echo "     sudo systemctl start bcm-node-ops-agent"
echo "     sudo journalctl -u bcm-node-ops-agent -f"
echo ""
