#!/bin/bash

# teardown.sh - Destroy all darkspace-tools infrastructure
# Removes traffic-host droplets, GRE tunnel, iptables rules, routing

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Load config
TARGET_IP=""
GRE_INTERFACE="darkspace-gre"
if [[ -f "$PROJECT_DIR/ansible/current-config.env" ]]; then
    source "$PROJECT_DIR/ansible/current-config.env"
fi

echo "========================================="
echo "  DESTROY DARKSPACE INFRASTRUCTURE"
echo "========================================="
echo ""
warning "This will destroy ALL darkspace-tools infrastructure!"
echo ""
echo "Actions:"
echo "  - Destroy all traffic-host droplets (DigitalOcean)"
echo "  - Remove GRE tunnel (${GRE_INTERFACE})"
echo "  - Clean up iptables NAT/FORWARD rules"
echo "  - Remove routing configuration"
echo ""
read -p "Type 'yes' to confirm: " -r
echo

[[ "$REPLY" != "yes" ]] && { echo "Cancelled"; exit 0; }

# Step 1: Destroy traffic-host droplets
log "Step 1: Destroying traffic-host droplets"

if command -v doctl &> /dev/null; then
    EXISTING=$(doctl compute droplet list --format ID,Name --no-header | grep "traffic-host" || true)
    if [[ -n "$EXISTING" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            DROPLET_ID=$(echo "$line" | awk '{print $1}')
            DROPLET_NAME=$(echo "$line" | awk '{print $2}')
            log "Destroying: $DROPLET_NAME ($DROPLET_ID)"
            doctl compute droplet delete "$DROPLET_ID" --force 2>/dev/null || warning "Failed to delete $DROPLET_NAME"
        done <<< "$EXISTING"

        WAIT_COUNT=0
        while doctl compute droplet list --format Name --no-header | grep -q "traffic-host" && [[ $WAIT_COUNT -lt 30 ]]; do
            sleep 5
            WAIT_COUNT=$((WAIT_COUNT + 1))
        done
        success "Droplets destroyed"
    else
        log "No traffic-host droplets found"
    fi
else
    warning "doctl not installed - skipping droplet destruction"
fi

# Step 2: Remove GRE tunnel
log "Step 2: Removing GRE tunnel"
if ip link show "$GRE_INTERFACE" &>/dev/null; then
    ip link set "$GRE_INTERFACE" down 2>/dev/null || true
    ip tunnel del "$GRE_INTERFACE" 2>/dev/null || true
    success "GRE tunnel removed"
else
    log "GRE tunnel not found"
fi

# Also remove netplan config
rm -f /etc/netplan/99-gre-tunnel.yaml
netplan apply 2>/dev/null || true

# Step 3: Clean iptables
log "Step 3: Cleaning iptables rules"
iptables -t nat -F PREROUTING 2>/dev/null || true
iptables -t nat -F POSTROUTING 2>/dev/null || true
iptables -F FORWARD 2>/dev/null || true
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
success "iptables cleaned"

# Step 4: Remove routing
log "Step 4: Removing routing configuration"
if [[ -n "$TARGET_IP" ]]; then
    ip rule del from "$TARGET_IP" 2>/dev/null || true
fi
ip route flush table 200 2>/dev/null || true
ip route flush table gre_replies 2>/dev/null || true
success "Routing removed"

# Step 5: Remove config files
log "Step 5: Removing configuration files"
rm -f "$PROJECT_DIR/ansible/traffic-host-inventory.yml"
rm -f "$PROJECT_DIR/ansible/inventory.yml"
rm -f "$PROJECT_DIR/ansible/config.yml"
rm -f "$PROJECT_DIR/ansible/current-config.env"
rm -f "$PROJECT_DIR/.env"
rm -f /usr/local/bin/gre-tunnel-status.sh
success "Config files removed"

echo ""
echo "========================================="
echo "  TEARDOWN COMPLETE"
echo "========================================="
echo ""
echo "Removed:"
echo "  - Traffic-host droplets"
echo "  - GRE tunnel ($GRE_INTERFACE)"
echo "  - iptables NAT/FORWARD rules"
echo "  - Policy routing rules"
echo "  - Configuration files"
echo ""
echo "Still exists (manual cleanup if needed):"
echo "  - VPC: doctl vpcs list && doctl vpcs delete <id>"
echo "  - SSH keys: doctl compute ssh-key list && doctl compute ssh-key delete <id>"
echo ""
echo "To redeploy: sudo bash scripts/setup.sh"
