#!/bin/bash

# configure-router-firewall.sh
# Configure UFW firewall on router for darkspace-tools operations
# Run on the router after initial deployment

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[1;37m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

[[ $EUID -ne 0 ]] && error "Must run as root"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Load configuration
if [[ -f "$PROJECT_DIR/.env" ]]; then
    source "$PROJECT_DIR/.env"
elif [[ -f "$PROJECT_DIR/ansible/current-config.env" ]]; then
    source "$PROJECT_DIR/ansible/current-config.env"
else
    error "No configuration found. Run setup.sh first."
fi

DARKSPACE_IP="${DARKSPACE_IP:-}"
GRE_INTERFACE="${GRE_INTERFACE:-darkspace-gre}"

[[ -z "$DARKSPACE_IP" ]] && error "DARKSPACE_IP not set"

# Auto-detect VPC network
VPC_NETWORK=""
for iface in eth1 ens4 enp0s4; do
    if ip link show "$iface" >/dev/null 2>&1; then
        VPC_NETWORK=$(ip addr show "$iface" | grep "inet " | awk '{print $2}')
        VPC_NETWORK="${VPC_NETWORK%/*}/20"
        break
    fi
done

echo "=== Router Firewall Configuration ==="
echo "  Darkspace Host: $DARKSPACE_IP"
echo "  GRE Interface:  $GRE_INTERFACE"
echo "  VPC Network:    ${VPC_NETWORK:-Not detected}"
echo ""

read -p "Configure UFW firewall? (y/N): " -n 1 -r
echo
[[ ! $REPLY =~ ^[Yy]$ ]] && { echo "Cancelled"; exit 0; }

# Install UFW
if ! command -v ufw &> /dev/null; then
    log "Installing UFW..."
    apt-get update && apt-get install -y ufw
fi

# Reset UFW
log "Resetting UFW..."
ufw --force reset

# Default policies
ufw default deny incoming
ufw default allow outgoing
ufw default allow routed

# Allow SSH
ufw allow 22/tcp comment 'SSH'

# Allow from VPC
if [[ -n "$VPC_NETWORK" ]]; then
    ufw allow from "$VPC_NETWORK" comment 'VPC network'
fi

# Allow GRE from darkspace host
ufw allow from "$DARKSPACE_IP" proto gre comment 'GRE from darkspace'

# Add GRE rules to before.rules
BEFORE_RULES="/etc/ufw/before.rules"
if [[ -f "$BEFORE_RULES" ]]; then
    cp "$BEFORE_RULES" "${BEFORE_RULES}.backup.$(date +%Y%m%d)"

    # Check if GRE rules already exist
    if ! grep -q "Allow GRE protocol" "$BEFORE_RULES"; then
        # Insert before the COMMIT line in the filter section
        sed -i '/^COMMIT$/i \
# Allow GRE protocol for tunnel\
-A ufw-before-input -p gre -j ACCEPT\
-A ufw-before-output -p gre -j ACCEPT\
-A ufw-before-forward -i '"$GRE_INTERFACE"' -j ACCEPT\
-A ufw-before-forward -o '"$GRE_INTERFACE"' -j ACCEPT' "$BEFORE_RULES"
        success "GRE rules added to UFW before.rules"
    fi
fi

# Enable UFW
ufw --force enable
success "UFW enabled"

ufw status verbose
