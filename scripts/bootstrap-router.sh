#!/bin/bash

# bootstrap-router.sh
# Initial system setup for a fresh router host
# Installs: Git, Ansible, Python, UFW, required packages

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }

[[ $EUID -ne 0 ]] && { echo "Must run as root"; exit 1; }

echo "=== Bootstrap Router System ==="
echo ""

log "Updating package cache..."
apt-get update

log "Installing base packages..."
apt-get install -y \
    git \
    ansible \
    python3 \
    python3-pip \
    iproute2 \
    iptables-persistent \
    netfilter-persistent \
    tcpdump \
    curl \
    wget \
    htop \
    vim \
    ufw \
    fail2ban \
    ipset \
    ntp \
    bind9-dnsutils \
    netcat-openbsd

# Load GRE kernel module
log "Loading GRE kernel module..."
modprobe ip_gre
echo "ip_gre" >> /etc/modules 2>/dev/null || true

# Enable IP forwarding
log "Enabling IP forwarding..."
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.d/99-darkspace.conf 2>/dev/null || true

# Configure fail2ban
log "Configuring fail2ban..."
cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
EOF

systemctl enable fail2ban
systemctl restart fail2ban

success "Bootstrap complete!"
echo ""
echo "Next steps:"
echo "  1. Clone the darkspace-tools repo"
echo "  2. Run: sudo bash scripts/setup.sh"
echo "  3. Run: sudo bash scripts/deploy.sh"
