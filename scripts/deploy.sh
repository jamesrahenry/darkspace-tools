#!/bin/bash

# deploy.sh - Main deployment script for darkspace-tools
# Reads profile from .env or DARKSPACE_PROFILE environment variable
#
# Profiles:
#   netflow       - Router only (GRE tunnel + iptables monitoring)
#   ids           - Router + traffic-host + Suricata IDS
#   honeypot-lite - Router + traffic-host + selected honeypot containers
#   honeypot-full - Router + traffic-host + full T-Pot (all services + ELK)

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }

validate_ip() {
    local ip="$1"
    local name="$2"
    if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        error "Invalid IP address format for $name: $ip"
    fi
    IFS='.' read -ra ADDR <<< "$ip"
    for i in "${ADDR[@]}"; do
        if [[ $i -gt 255 || $i -lt 0 ]]; then
            error "Invalid IP address for $name: $ip"
        fi
    done
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

# Load configuration
if [[ -f "ansible/current-config.env" ]]; then
    log "Loading configuration..."
    source ansible/current-config.env
fi

PROFILE="${DARKSPACE_PROFILE:-netflow}"
TARGET_IP="${TARGET_IP:-198.51.100.50}"
DARKSPACE_IP="${DARKSPACE_IP:-203.0.113.10}"
VPC_REGION="${VPC_REGION:-tor1}"
SERVICES="${DARKSPACE_SERVICES:-all}"

# Validate
validate_ip "$TARGET_IP" "TARGET_IP"
validate_ip "$DARKSPACE_IP" "DARKSPACE_IP"

echo "=== Darkspace Tools Deployment ==="
echo ""
echo "  Profile:      $PROFILE"
echo "  Target IP:    $TARGET_IP"
echo "  Darkspace IP: $DARKSPACE_IP"
if [[ "$PROFILE" != "netflow" ]]; then
    echo "  Region:       $VPC_REGION"
fi
if [[ "$PROFILE" == "honeypot-lite" ]]; then
    echo "  Services:     $SERVICES"
fi
echo ""

read -p "Continue with deployment? (y/N): " -n 1 -r
echo
[[ ! $REPLY =~ ^[Yy]$ ]] && { echo "Cancelled"; exit 0; }

# Step 1: Prerequisites
log "Step 1: Checking prerequisites"

if ! command -v ansible &> /dev/null; then
    log "Installing Ansible..."
    apt-get update && apt-get install -y ansible
fi

if [[ "$PROFILE" != "netflow" ]] && ! command -v doctl &> /dev/null; then
    error "doctl not installed. See: https://docs.digitalocean.com/reference/doctl/how-to/install/"
fi

success "Prerequisites verified"

# Step 2: Set environment variables for Ansible
log "Step 2: Setting environment"
export TARGET_IP DARKSPACE_IP VPC_REGION DARKSPACE_PROFILE="$PROFILE" DARKSPACE_SERVICES="$SERVICES"

# Detect VPC interface
VPC_INTERFACE=""
for iface in eth1 ens4 enp0s4; do
    if ip link show "$iface" >/dev/null 2>&1; then
        VPC_INTERFACE="$iface"
        break
    fi
done

# Step 3: Deploy router (ALL profiles)
log "Step 3: Deploying router configuration"

cd ansible

VAULT_ARGS=""
if [[ -f "$HOME/.vault_pass" ]]; then
    VAULT_ARGS="--vault-password-file $HOME/.vault_pass"
elif [[ "$PROFILE" == "honeypot-lite" || "$PROFILE" == "honeypot-full" ]]; then
    VAULT_ARGS="--ask-vault-pass"
fi

ansible-playbook deploy-all.yml --limit localhost $VAULT_ARGS -v \
    -e "profile=$PROFILE"

success "Router configured"
cd "$PROJECT_DIR"

# For netflow profile, configure monitoring and we're done
if [[ "$PROFILE" == "netflow" ]]; then
    log "Configuring netflow monitoring..."
    if [[ -f "scripts/configure-netflow-monitoring.sh" ]]; then
        bash scripts/configure-netflow-monitoring.sh
    fi
    echo ""
    echo "=== NETFLOW DEPLOYMENT COMPLETE ==="
    echo "  GRE tunnel: Active"
    echo "  Monitoring: iptables netflow rules configured"
    echo ""
    echo "  View traffic: sudo tcpdump -i ${GRE_INTERFACE:-darkspace-gre} -n"
    echo "  View counts:  sudo iptables -L -n -v | grep NETFLOW"
    echo "  Diagnose:     sudo bash scripts/diagnose.sh"
    exit 0
fi

# Step 4: Create traffic-host (ids, honeypot-lite, honeypot-full)
log "Step 4: Creating traffic-host droplet"

VPC_NAME="honeypot-vpc"
VPC_ID=$(doctl vpcs list --format ID,Name --no-header | grep "$VPC_NAME" | awk '{print $1}' || true)
if [[ -z "$VPC_ID" ]]; then
    error "VPC '$VPC_NAME' not found. Create it first: doctl vpcs create --name $VPC_NAME --region $VPC_REGION --ip-range 10.100.0.0/20"
fi

# Find SSH key
SSH_KEY_ID=""
for local_key in ~/.ssh/id_*; do
    [[ "$local_key" == *.pub ]] && continue
    [[ ! -f "$local_key" ]] && continue
    LOCAL_FP=$(ssh-keygen -l -E md5 -f "$local_key" 2>/dev/null | awk '{print $2}' | sed 's/MD5://')
    if [[ -n "$LOCAL_FP" ]]; then
        MATCHING_KEY=$(doctl compute ssh-key list --format ID,FingerPrint --no-header | grep "$LOCAL_FP" || true)
        if [[ -n "$MATCHING_KEY" ]]; then
            SSH_KEY_ID=$(echo "$MATCHING_KEY" | awk '{print $1}')
            SSH_KEY_PATH="$local_key"
            break
        fi
    fi
done

if [[ -z "$SSH_KEY_ID" ]]; then
    SSH_KEY_ID=$(doctl compute ssh-key list --format ID --no-header | head -1)
    SSH_KEY_PATH="${SSH_KEY_PATH:-~/.ssh/id_ed25519}"
fi

# Destroy existing traffic-host
EXISTING=$(doctl compute droplet list --format ID,Name --no-header | grep "traffic-host" || true)
if [[ -n "$EXISTING" ]]; then
    log "Destroying existing traffic-host..."
    while IFS= read -r line; do
        [[ -n "$line" ]] && doctl compute droplet delete "$(echo "$line" | awk '{print $1}')" --force 2>/dev/null || true
    done <<< "$EXISTING"
    sleep 10
fi

TRAFFIC_HOST_ID="${TRAFFIC_HOST_ID:-01}"
log "Creating traffic-host-${TRAFFIC_HOST_ID}..."
doctl compute droplet create "traffic-host-${TRAFFIC_HOST_ID}" \
    --image "debian-13-x64" \
    --size "s-2vcpu-2gb" \
    --region "$VPC_REGION" \
    --vpc-uuid "$VPC_ID" \
    --ssh-keys "$SSH_KEY_ID" \
    --format ID,Name,Status \
    --no-header

NEW_DROPLET_ID=$(doctl compute droplet list --format ID,Name --no-header | grep "traffic-host-${TRAFFIC_HOST_ID}" | awk '{print $1}')

# Wait for active
log "Waiting for droplet..."
while true; do
    STATUS=$(doctl compute droplet get "$NEW_DROPLET_ID" --format Status --no-header)
    [[ "$STATUS" == "active" ]] && break
    sleep 10
done

# Wait for private IP
WAIT_ATTEMPTS=0
while [[ $WAIT_ATTEMPTS -lt 30 ]]; do
    NEW_PRIVATE_IP=$(doctl compute droplet get "$NEW_DROPLET_ID" --format PrivateIPv4 --no-header 2>/dev/null || echo "")
    [[ -n "$NEW_PRIVATE_IP" ]] && break
    WAIT_ATTEMPTS=$((WAIT_ATTEMPTS + 1))
    sleep 10
done
[[ -z "$NEW_PRIVATE_IP" ]] && error "Failed to get private IP"
success "Traffic-host IP: $NEW_PRIVATE_IP"

# Step 5: Create inventory for traffic-host
log "Step 5: Creating traffic-host inventory"
ROUTER_VPC_IP=$(ip addr show "${VPC_INTERFACE:-eth1}" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1)

cat > ansible/traffic-host-inventory.yml << EOF
all:
  children:
    traffic_hosts:
      hosts:
        traffic-host-${TRAFFIC_HOST_ID}:
          ansible_host: $NEW_PRIVATE_IP
          ansible_user: root
          ansible_ssh_private_key_file: $SSH_KEY_PATH
          target_ip: $TARGET_IP
          router_vpc_ip: ${ROUTER_VPC_IP:-10.100.0.2}
          droplet_id: $NEW_DROPLET_ID
  vars:
    ansible_ssh_common_args: '-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
    ansible_python_interpreter: /usr/bin/python3
EOF

# Step 6: Deploy traffic-host
log "Step 6: Deploying traffic-host (waiting 60s for init)..."
sleep 60

cd ansible
ansible-playbook -i traffic-host-inventory.yml deploy-all.yml --limit traffic_hosts $VAULT_ARGS -v \
    -e "profile=$PROFILE" -e "services=$SERVICES"

success "Traffic-host configured"
cd "$PROJECT_DIR"

# Step 7: Configure router routing
log "Step 7: Configuring router routing"
validate_ip "$NEW_PRIVATE_IP" "traffic-host private IP"

ip route del "$TARGET_IP/32" 2>/dev/null || true
ip route add "$TARGET_IP/32" via "$NEW_PRIVATE_IP" dev "${VPC_INTERFACE:-eth1}"

ip rule del from "$TARGET_IP" 2>/dev/null || true
ip rule add from "$TARGET_IP" table 200 priority 100

ip route flush table 200 2>/dev/null || true
ip route add 192.168.240.0/29 dev "${GRE_INTERFACE:-darkspace-gre}" table 200
ip route add default via 192.168.240.2 dev "${GRE_INTERFACE:-darkspace-gre}" table 200

# DNAT + SNAT + FORWARD
iptables -t nat -D PREROUTING -d "$TARGET_IP" -j DNAT --to-destination "$NEW_PRIVATE_IP" 2>/dev/null || true
iptables -t nat -A PREROUTING -d "$TARGET_IP" -j DNAT --to-destination "$NEW_PRIVATE_IP"

iptables -t nat -D POSTROUTING -s "$NEW_PRIVATE_IP" -j SNAT --to-source "$TARGET_IP" 2>/dev/null || true
iptables -t nat -A POSTROUTING -s "$NEW_PRIVATE_IP" -j SNAT --to-source "$TARGET_IP"

mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4

success "Router routing configured"

# Step 8: Test
log "Step 8: Testing deployment"
sleep 5

if [[ "$TARGET_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    if timeout 10 curl -s "http://$TARGET_IP" | grep -q "Darkspace"; then
        success "Target IP responding!"
    else
        warning "Target IP not responding yet - may need a moment"
    fi
fi

echo ""
echo "=== DEPLOYMENT COMPLETE ==="
echo "  Profile:  $PROFILE"
echo "  Target:   $TARGET_IP"
echo ""
echo "  Test:     ping $TARGET_IP"
echo "            curl http://$TARGET_IP"
echo "  Diagnose: sudo bash scripts/diagnose.sh"
if [[ "$PROFILE" == "honeypot-full" ]]; then
    echo "  Web UI:   https://$NEW_PRIVATE_IP:64297"
fi
echo ""
