#!/bin/bash

# configure-netflow-monitoring.sh
# Set up iptables raw table rules for kernel-level traffic monitoring
# Core of the "netflow" profile - works with just a GRE tunnel (no honeypot needed)
#
# Creates:
#   - ipsets for darkspace and honeypot network tracking
#   - iptables NETFLOW rules in the raw table
#   - Persistent rules that survive reboots

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

[[ $EUID -ne 0 ]] && error "Must run as root"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Load configuration
GRE_INTERFACE="darkspace-gre"
if [[ -f "$PROJECT_DIR/ansible/current-config.env" ]]; then
    source "$PROJECT_DIR/ansible/current-config.env"
fi
GRE_INTERFACE="${GRE_INTERFACE:-darkspace-gre}"

echo "=== NetFlow Monitoring Configuration ==="
echo "GRE Interface: $GRE_INTERFACE"
echo ""

# Install ipset if needed
if ! command -v ipset &> /dev/null; then
    log "Installing ipset..."
    apt-get update && apt-get install -y ipset
fi

# Create ipsets for network tracking
log "Creating ipsets..."

# Darkspace networks set (networks sending traffic through GRE)
if ! ipset list darkspace-nets &>/dev/null; then
    ipset create darkspace-nets hash:net family inet hashsize 1024 maxelem 65536 \
        comment timeout 86400
    success "Created ipset: darkspace-nets"
else
    log "ipset darkspace-nets already exists"
fi

# Honeypot target IPs set
if ! ipset list honeypot-ips &>/dev/null; then
    ipset create honeypot-ips hash:ip family inet hashsize 1024 maxelem 256 comment
    success "Created ipset: honeypot-ips"
else
    log "ipset honeypot-ips already exists"
fi

# Add target IP to honeypot set if configured
TARGET_IP="${TARGET_IP:-}"
if [[ -n "$TARGET_IP" ]]; then
    ipset add honeypot-ips "$TARGET_IP" comment "target" 2>/dev/null || true
    success "Added $TARGET_IP to honeypot-ips"
fi

# Detect active GRE tunnels and configure NETFLOW rules
log "Configuring iptables NETFLOW rules..."

# Check if GRE interface exists
if ! ip link show "$GRE_INTERFACE" &>/dev/null; then
    error "GRE interface $GRE_INTERFACE not found. Deploy router first."
fi

# Create NETFLOW chain in raw table if not exists
if ! iptables -t raw -L NETFLOW &>/dev/null 2>&1; then
    iptables -t raw -N NETFLOW
    success "Created NETFLOW chain in raw table"
fi

# Flush existing NETFLOW rules
iptables -t raw -F NETFLOW

# Add monitoring rules for GRE tunnel traffic
# Count all packets entering via GRE
iptables -t raw -A NETFLOW -i "$GRE_INTERFACE" -m comment --comment "netflow-gre-inbound" -j RETURN

# Count all packets leaving via GRE
iptables -t raw -A NETFLOW -o "$GRE_INTERFACE" -m comment --comment "netflow-gre-outbound" -j RETURN

# Count traffic matching honeypot IPs
iptables -t raw -A NETFLOW -m set --match-set honeypot-ips dst -m comment --comment "netflow-honeypot-dst" -j RETURN
iptables -t raw -A NETFLOW -m set --match-set honeypot-ips src -m comment --comment "netflow-honeypot-src" -j RETURN

# Count traffic from darkspace networks
iptables -t raw -A NETFLOW -m set --match-set darkspace-nets src -m comment --comment "netflow-darkspace-src" -j RETURN

# Hook NETFLOW chain into PREROUTING
if ! iptables -t raw -C PREROUTING -j NETFLOW 2>/dev/null; then
    iptables -t raw -A PREROUTING -j NETFLOW
fi

# Hook NETFLOW chain into OUTPUT
if ! iptables -t raw -C OUTPUT -j NETFLOW 2>/dev/null; then
    iptables -t raw -A OUTPUT -j NETFLOW
fi

success "NETFLOW rules configured"

# Save ipset and iptables rules
log "Saving rules for persistence..."

mkdir -p /etc/ipset
ipset save > /etc/ipset/ipset.rules
success "ipset rules saved to /etc/ipset/ipset.rules"

mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4
success "iptables rules saved to /etc/iptables/rules.v4"

echo ""
echo "=== NetFlow Monitoring Active ==="
echo ""
echo "View live traffic:"
echo "  sudo tcpdump -i $GRE_INTERFACE -n"
echo ""
echo "View packet counters:"
echo "  sudo iptables -t raw -L NETFLOW -n -v"
echo ""
echo "View ipset contents:"
echo "  sudo ipset list darkspace-nets"
echo "  sudo ipset list honeypot-ips"
echo ""
echo "Add a darkspace network:"
echo "  sudo ipset add darkspace-nets 192.0.2.0/24 comment 'example network'"
echo ""
