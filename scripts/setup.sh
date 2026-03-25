#!/bin/bash

# setup.sh - Interactive configuration wizard for darkspace-tools
# Gathers network info, cloud credentials, and creates configuration files
# Supports profile selection: netflow, ids, honeypot-lite, honeypot-full

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root" >&2
    exit 1
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
prompt() { echo -e "${CYAN}[INPUT]${NC} $1"; }

validate_ip() {
    local ip="$1"
    if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 1
    fi
    IFS='.' read -ra ADDR <<< "$ip"
    for i in "${ADDR[@]}"; do
        if [[ $i -gt 255 || $i -lt 0 ]]; then
            return 1
        fi
    done
    return 0
}

validate_region() {
    local region="$1"
    [[ "$region" =~ ^[a-z0-9-]+$ ]]
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "========================================="
echo "  Darkspace Tools - Configuration Wizard"
echo "========================================="
echo ""

# Step 0: Profile Selection
echo "=== Step 0: Select Deployment Profile ==="
echo ""
echo "Available profiles:"
echo ""
echo "  1) netflow        - GRE tunnel + kernel-level traffic monitoring"
echo "                      Router only. ~50MB, 5 min deploy."
echo ""
echo "  2) ids             - Above + Suricata IDS on target IP"
echo "                      Router + Traffic-Host. ~300MB, 15 min."
echo ""
echo "  3) honeypot-lite   - Above + pick individual honeypot services"
echo "                      Cowrie, Dionaea, Honeytrap, Mailoney. ~500MB, 20 min."
echo ""
echo "  4) honeypot-full   - Above + full T-Pot (all honeypots + ELK + Kibana)"
echo "                      Complete ecosystem. ~3GB, 60 min."
echo ""

while true; do
    prompt "Select profile [1-4]:"
    read -r PROFILE_NUM
    case "$PROFILE_NUM" in
        1) PROFILE="netflow"; break ;;
        2) PROFILE="ids"; break ;;
        3) PROFILE="honeypot-lite"; break ;;
        4) PROFILE="honeypot-full"; break ;;
        *) error "Invalid selection. Enter 1-4." ;;
    esac
done
success "Profile: $PROFILE"

# For honeypot-lite, select services
SERVICES="all"
if [[ "$PROFILE" == "honeypot-lite" ]]; then
    echo ""
    echo "Select honeypot services to deploy:"
    echo "  c) Cowrie     - SSH/Telnet honeypot (ports 22, 23)"
    echo "  d) Dionaea    - Multi-protocol honeypot (FTP, HTTP, SMB, SQL, etc.)"
    echo "  h) Honeytrap  - Email protocol honeypot (POP3, IMAP)"
    echo "  m) Mailoney   - SMTP honeypot (port 25)"
    echo "  s) Suricata   - Network IDS (passive, included by default)"
    echo ""
    prompt "Enter service letters (e.g., 'cds' for Cowrie+Dionaea+Suricata):"
    read -r SERVICE_SELECTION

    SELECTED=()
    [[ "$SERVICE_SELECTION" == *c* ]] && SELECTED+=("cowrie")
    [[ "$SERVICE_SELECTION" == *d* ]] && SELECTED+=("dionaea")
    [[ "$SERVICE_SELECTION" == *h* ]] && SELECTED+=("honeytrap")
    [[ "$SERVICE_SELECTION" == *m* ]] && SELECTED+=("mailoney")
    SELECTED+=("suricata")  # Always include Suricata
    SERVICES=$(IFS=,; echo "${SELECTED[*]}")
    success "Services: $SERVICES"
fi

# Step 1: Network Configuration
echo ""
echo "=== Step 1: Network Configuration ==="
echo ""

# Get router public IP (auto-detect)
while true; do
    DETECTED_IP=$(curl -s -4 ifconfig.me 2>/dev/null || curl -s -4 icanhazip.com 2>/dev/null || echo "")
    if [[ -n "$DETECTED_IP" ]]; then
        prompt "Router Public IP detected as: $DETECTED_IP"
        read -p "Use this IP? (Y/n): " -r
        if [[ $REPLY =~ ^[Nn]$ ]]; then
            prompt "Enter Router Public IP:"
            read -r ROUTER_PUBLIC_IP
        else
            ROUTER_PUBLIC_IP="$DETECTED_IP"
        fi
    else
        prompt "Enter Router Public IP:"
        read -r ROUTER_PUBLIC_IP
    fi

    if validate_ip "$ROUTER_PUBLIC_IP"; then
        success "Router Public IP: $ROUTER_PUBLIC_IP"
        break
    else
        error "Invalid IP address. Try again."
    fi
done

# Get darkspace/GRE host IP
while true; do
    prompt "Enter Darkspace/GRE Host IP (remote tunnel endpoint):"
    read -r DARKSPACE_IP

    if validate_ip "$DARKSPACE_IP"; then
        success "Darkspace IP: $DARKSPACE_IP"
        break
    else
        error "Invalid IP address. Try again."
    fi
done

# Get target IP
while true; do
    prompt "Enter Target IP (IP address for honeypot/monitoring traffic):"
    read -r TARGET_IP

    if validate_ip "$TARGET_IP"; then
        success "Target IP: $TARGET_IP"
        break
    else
        error "Invalid IP address. Try again."
    fi
done

# GRE defaults
prompt "Enter GRE Local IP [default: 192.168.240.1]:"
read -r GRE_LOCAL_IP
GRE_LOCAL_IP="${GRE_LOCAL_IP:-192.168.240.1}"
success "GRE Local IP: $GRE_LOCAL_IP"

prompt "Enter GRE Interface Name [default: darkspace-gre]:"
read -r GRE_INTERFACE
GRE_INTERFACE="${GRE_INTERFACE:-darkspace-gre}"
success "GRE Interface: $GRE_INTERFACE"

# Step 2: Cloud Provider (only for profiles that need a traffic-host)
if [[ "$PROFILE" != "netflow" ]]; then
    echo ""
    echo "=== Step 2: DigitalOcean Configuration ==="
    echo ""

    if command -v doctl &> /dev/null; then
        if doctl compute region list &> /dev/null; then
            success "doctl is installed and authenticated"
            DOCTL_AUTHENTICATED=true
        else
            warning "doctl is installed but not authenticated"
            DOCTL_AUTHENTICATED=false
        fi
    else
        warning "doctl is not installed"
        DOCTL_AUTHENTICATED=false
    fi

    if [[ "$DOCTL_AUTHENTICATED" == "false" ]]; then
        echo ""
        echo "DigitalOcean CLI (doctl) is required for traffic-host deployment."
        echo "1. Get API token: https://cloud.digitalocean.com/account/api/tokens"
        echo "2. Install doctl: https://docs.digitalocean.com/reference/doctl/how-to/install/"
        echo ""

        prompt "Do you have a DigitalOcean API token? (y/N):"
        read -r HAS_TOKEN

        if [[ $HAS_TOKEN =~ ^[Yy]$ ]]; then
            if ! command -v doctl &> /dev/null; then
                error "Please install doctl first. See: https://docs.digitalocean.com/reference/doctl/how-to/install/"
                exit 1
            fi
            log "Authenticating doctl..."
            doctl auth init
        else
            error "DigitalOcean API token required for this profile."
            exit 1
        fi
    fi

    log "Available regions:"
    doctl compute region list --format Slug,Name,Available 2>/dev/null | head -20

    while true; do
        prompt "Enter DigitalOcean region [default: tor1]:"
        read -r DO_REGION
        DO_REGION="${DO_REGION:-tor1}"

        if validate_region "$DO_REGION"; then
            success "Region: $DO_REGION"
            break
        else
            error "Invalid region format."
        fi
    done
else
    DO_REGION="local"
fi

# Step 3: SSH Configuration (for profiles with traffic-host)
if [[ "$PROFILE" != "netflow" ]]; then
    echo ""
    echo "=== Step 3: SSH Configuration ==="
    echo ""

    HOSTNAME=$(hostname)
    SSH_KEY_NAME="id_${HOSTNAME}"
    SSH_KEY_PATH="$HOME/.ssh/${SSH_KEY_NAME}"

    if [[ -f "$SSH_KEY_PATH" ]]; then
        success "Found SSH key: $SSH_KEY_PATH"
        GENERATE_KEY=false
    else
        log "Generating SSH key: $SSH_KEY_PATH"
        ssh-keygen -t ed25519 -C "darkspace@${HOSTNAME}" -f "$SSH_KEY_PATH" -N ""
        success "SSH key generated"
        GENERATE_KEY=true
    fi

    # Check DigitalOcean for SSH key
    DO_KEY_NAME="darkspace-ssh-key"
    if doctl compute ssh-key list --format Name --no-header 2>/dev/null | grep -q "$DO_KEY_NAME"; then
        success "SSH key '$DO_KEY_NAME' found in DigitalOcean"
    else
        warning "SSH key not in DigitalOcean"
        prompt "Upload SSH key? (Y/n):"
        read -r UPLOAD_KEY

        if [[ ! $UPLOAD_KEY =~ ^[Nn]$ ]]; then
            doctl compute ssh-key import "$DO_KEY_NAME" --public-key-file "${SSH_KEY_PATH}.pub"
            success "SSH key uploaded to DigitalOcean"
        fi
    fi
else
    SSH_KEY_PATH="$HOME/.ssh/id_ed25519"
fi

# Step 4: Ansible Vault (for profiles with secrets)
if [[ "$PROFILE" == "honeypot-lite" || "$PROFILE" == "honeypot-full" ]]; then
    echo ""
    echo "=== Step 4: Ansible Vault Configuration ==="
    echo ""

    VAULT_PASS_FILE="$HOME/.vault_pass"

    if [[ -f "$VAULT_PASS_FILE" ]]; then
        success "Vault password file exists: $VAULT_PASS_FILE"
    else
        log "Generating vault password..."
        openssl rand -base64 32 > "$VAULT_PASS_FILE"
        chmod 600 "$VAULT_PASS_FILE"
        success "Vault password generated: $VAULT_PASS_FILE"
    fi
fi

# Step 5: Generate configuration files
echo ""
echo "=== Generating Configuration Files ==="
echo ""

# Create .env
cat > "$PROJECT_DIR/.env" << EOF
# Darkspace Tools Configuration
# Generated: $(date)
# Profile: $PROFILE

# Deployment Profile
DARKSPACE_PROFILE=$PROFILE
DARKSPACE_SERVICES=$SERVICES

# Network
TARGET_IP=$TARGET_IP
DARKSPACE_IP=$DARKSPACE_IP
GRE_LOCAL_IP=$GRE_LOCAL_IP
GRE_INTERFACE=$GRE_INTERFACE
GRE_TUNNEL_KEY=401

# Cloud
VPC_REGION=$DO_REGION

# T-Pot (honeypot-lite / honeypot-full only)
TPOT_VERSION=24.04.1
TPOT_USER=honeypot
TPOT_WEB_PORT=64297

# Docker
COMPOSE_PROJECT_NAME=tpotce
TPOT_PULL_POLICY=if_not_present
EOF
success "Created: .env"

# Create Ansible inventory
cat > "$PROJECT_DIR/ansible/inventory.yml" << EOF
# Ansible Inventory - Generated by setup.sh
# Profile: $PROFILE
all:
  children:
    routers:
      hosts:
        localhost:
          ansible_host: localhost
          ansible_user: root
          ansible_connection: local
          gre_remote_ip: $DARKSPACE_IP
          gre_local_ip: $GRE_LOCAL_IP
          gre_interface: $GRE_INTERFACE
          target_ip: $TARGET_IP
          vpc_region: $DO_REGION

    traffic_hosts:
      hosts:
        traffic-host:
          ansible_user: root
          ansible_ssh_private_key_file: $SSH_KEY_PATH
          target_ip: $TARGET_IP

  vars:
    ansible_ssh_common_args: '-o ConnectTimeout=30 -o StrictHostKeyChecking=no'
    ansible_python_interpreter: /usr/bin/python3
EOF
success "Created: ansible/inventory.yml"

# Save config for deployment script
cat > "$PROJECT_DIR/ansible/current-config.env" << EOF
TARGET_IP=$TARGET_IP
DARKSPACE_IP=$DARKSPACE_IP
GRE_LOCAL_IP=$GRE_LOCAL_IP
GRE_INTERFACE=$GRE_INTERFACE
VPC_REGION=$DO_REGION
DARKSPACE_PROFILE=$PROFILE
DARKSPACE_SERVICES=$SERVICES
SSH_KEY_PATH=$SSH_KEY_PATH
EOF
success "Created: ansible/current-config.env"

# Summary
echo ""
echo "========================================="
echo "  Configuration Complete!"
echo "========================================="
echo ""
echo "  Profile:        $PROFILE"
echo "  Target IP:      $TARGET_IP"
echo "  Darkspace IP:   $DARKSPACE_IP"
echo "  GRE Interface:  $GRE_INTERFACE"
if [[ "$PROFILE" != "netflow" ]]; then
    echo "  Region:         $DO_REGION"
    echo "  SSH Key:        $SSH_KEY_PATH"
fi
if [[ "$PROFILE" == "honeypot-lite" ]]; then
    echo "  Services:       $SERVICES"
fi
echo ""
echo "Next steps:"
echo "  cd $PROJECT_DIR"
if [[ "$PROFILE" == "netflow" ]]; then
    echo "  make deploy PROFILE=netflow"
else
    echo "  make deploy PROFILE=$PROFILE"
fi
echo ""
echo "  Or run directly:"
echo "  sudo bash scripts/deploy.sh"
echo ""
