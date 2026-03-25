#!/bin/bash

# diagnose.sh - End-to-end connectivity diagnostics for darkspace-tools
# Runs 9 categories of checks, profile-aware

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root" >&2
    exit 1
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
error() { echo -e "${RED}[FAIL]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Load config
if [[ -f "$PROJECT_DIR/ansible/current-config.env" ]]; then
    source "$PROJECT_DIR/ansible/current-config.env"
elif [[ -f "$PROJECT_DIR/.env" ]]; then
    source "$PROJECT_DIR/.env"
fi
GRE_INTERFACE="${GRE_INTERFACE:-darkspace-gre}"
TARGET_IP="${TARGET_IP:-198.51.100.50}"
PROFILE="${DARKSPACE_PROFILE:-netflow}"

# Try to discover traffic-host VPC IP
TRAFFIC_HOST_VPC_IP=$(ip route show | grep "$TARGET_IP" | awk '{print $3}' | head -1 || true)

echo "========================================="
echo "  Darkspace Tools - Diagnostics"
echo "========================================="
echo "Profile: $PROFILE"
echo "Target IP: $TARGET_IP"
echo "GRE Interface: $GRE_INTERFACE"
[[ -n "$TRAFFIC_HOST_VPC_IP" ]] && echo "Traffic-Host VPC IP: $TRAFFIC_HOST_VPC_IP"
echo ""

# 1. GRE Tunnel
log "1. Checking GRE Tunnel"
if ip link show "$GRE_INTERFACE" >/dev/null 2>&1; then
    STATE=$(ip link show "$GRE_INTERFACE" | grep -o "state [A-Z]*" | awk '{print $2}')
    if [[ "$STATE" == "UP" || "$STATE" == "UNKNOWN" ]]; then
        success "GRE tunnel exists (state: $STATE)"
    else
        warning "GRE tunnel exists but state: $STATE"
    fi
    ip addr show "$GRE_INTERFACE" | grep "inet " | sed 's/^/  /'
else
    error "GRE tunnel '$GRE_INTERFACE' not found"
fi
echo ""

# 2. VPC Connectivity (skip for netflow-only)
if [[ "$PROFILE" != "netflow" && -n "$TRAFFIC_HOST_VPC_IP" ]]; then
    log "2. Checking VPC Connectivity"
    if ping -c 2 -W 2 "$TRAFFIC_HOST_VPC_IP" >/dev/null 2>&1; then
        success "Traffic-host reachable at $TRAFFIC_HOST_VPC_IP"
    else
        error "Cannot reach traffic-host at $TRAFFIC_HOST_VPC_IP"
    fi
    echo ""
else
    log "2. VPC Connectivity - Skipped (profile: $PROFILE)"
    echo ""
fi

# 3. Routing
log "3. Checking Routing Configuration"
echo "  Main routes:"
ip route show | grep -E "(default|$TARGET_IP|192.168.240)" | sed 's/^/    /'

echo "  Policy routing:"
ip rule show | grep -E "($TARGET_IP|gre_replies)" | sed 's/^/    /' || echo "    No policy rules for target IP"

echo "  GRE replies table:"
ip route show table gre_replies 2>/dev/null | sed 's/^/    /' || echo "    Table not configured"
echo ""

# 4. NAT Rules (skip for netflow)
if [[ "$PROFILE" != "netflow" ]]; then
    log "4. Checking NAT Configuration"
    echo "  DNAT rules:"
    iptables -t nat -L PREROUTING -n -v 2>/dev/null | grep "$TARGET_IP" | sed 's/^/    /' || echo "    No DNAT rules"

    echo "  SNAT rules:"
    iptables -t nat -L POSTROUTING -n -v 2>/dev/null | grep -E "($TARGET_IP)" | sed 's/^/    /' || echo "    No SNAT rules"

    echo "  MASQUERADE rules:"
    iptables -t nat -L POSTROUTING -n -v 2>/dev/null | grep MASQUERADE | sed 's/^/    /' || echo "    No MASQUERADE rules"
    echo ""
else
    log "4. NAT Rules - Skipped (netflow profile)"
    echo ""
fi

# 5. FORWARD Rules
log "5. Checking FORWARD Rules"
iptables -L FORWARD -n -v 2>/dev/null | grep -E "($GRE_INTERFACE|eth1)" | head -10 | sed 's/^/  /' || echo "  No FORWARD rules"
echo ""

# 6. Netflow/iptables monitoring (for netflow profile)
if [[ "$PROFILE" == "netflow" ]]; then
    log "6. Checking Netflow Monitoring"
    echo "  Raw table NETFLOW rules:"
    iptables -t raw -L -n -v 2>/dev/null | grep -i "netflow\|NFLOG" | sed 's/^/    /' || echo "    No NETFLOW rules"

    echo "  Ipsets:"
    ipset list -n 2>/dev/null | sed 's/^/    /' || echo "    No ipsets"
    echo ""
else
    log "6. Netflow Monitoring - N/A for this profile"
    echo ""
fi

# 7. Traffic-Host Configuration (skip for netflow)
if [[ "$PROFILE" != "netflow" && -n "$TRAFFIC_HOST_VPC_IP" ]]; then
    log "7. Checking Traffic-Host Configuration"
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$TRAFFIC_HOST_VPC_IP" "true" 2>/dev/null; then
        success "SSH access to traffic-host"

        echo "  Target IP binding:"
        ssh -o StrictHostKeyChecking=no root@"$TRAFFIC_HOST_VPC_IP" "ip addr show dummy0 | grep 'inet '" 2>/dev/null | sed 's/^/    /'

        echo "  Default route:"
        ssh -o StrictHostKeyChecking=no root@"$TRAFFIC_HOST_VPC_IP" "ip route show default" 2>/dev/null | sed 's/^/    /'

        if [[ "$PROFILE" == "honeypot-lite" || "$PROFILE" == "honeypot-full" ]]; then
            echo "  Docker containers:"
            ssh -o StrictHostKeyChecking=no root@"$TRAFFIC_HOST_VPC_IP" \
                "docker ps --format '{{.Names}}: {{.Status}}' 2>/dev/null | head -10" | sed 's/^/    /' \
                || echo "    No containers running"
        fi
    else
        error "Cannot SSH to traffic-host"
    fi
    echo ""
else
    log "7. Traffic-Host - Skipped"
    echo ""
fi

# 8. End-to-End Connectivity
log "8. Testing End-to-End Connectivity"

echo "  ICMP (ping):"
if ping -c 2 -W 2 "$TARGET_IP" >/dev/null 2>&1; then
    success "  Ping successful"
else
    warning "  Ping failed"
fi

if [[ "$PROFILE" != "netflow" ]]; then
    echo "  HTTP (port 80):"
    HTTP_RESULT=$(timeout 3 curl -s -o /dev/null -w "%{http_code}" "http://$TARGET_IP" 2>/dev/null || echo "timeout")
    if [[ "$HTTP_RESULT" != "timeout" && "$HTTP_RESULT" != "000" ]]; then
        success "  HTTP responding (code: $HTTP_RESULT)"
    else
        warning "  HTTP not responding"
    fi

    echo "  SSH (port 22):"
    if timeout 2 nc -zv "$TARGET_IP" 22 2>&1 | grep -q "succeeded"; then
        success "  SSH port open"
    else
        warning "  SSH port not responding"
    fi
fi
echo ""

# 9. Packet Counters
log "9. Checking Packet Counters"
if [[ "$PROFILE" != "netflow" ]]; then
    echo "  DNAT hits:"
    iptables -t nat -L PREROUTING -n -v 2>/dev/null | grep "$TARGET_IP" | awk '{print "    Packets: "$1", Bytes: "$2}'

    echo "  FORWARD hits (GRE→VPC):"
    iptables -L FORWARD -n -v 2>/dev/null | grep "$GRE_INTERFACE.*eth1" | awk '{print "    Packets: "$1", Bytes: "$2}'

    echo "  FORWARD hits (VPC→GRE):"
    iptables -L FORWARD -n -v 2>/dev/null | grep "eth1.*$GRE_INTERFACE" | awk '{print "    Packets: "$1", Bytes: "$2}'
else
    echo "  GRE interface stats:"
    ip -s link show "$GRE_INTERFACE" 2>/dev/null | grep -A1 "RX\|TX" | sed 's/^/    /'
fi
echo ""

# Summary
echo "========================================="
echo "  Diagnostic Summary"
echo "========================================="
echo ""
echo "Troubleshooting:"
echo "  1. GRE tunnel down: Check remote endpoint connectivity"
echo "  2. No DNAT/SNAT: Re-run deploy.sh"
echo "  3. Wrong source IP in replies: Check policy routing tables"
echo "  4. Containers not running: ssh root@<vpc-ip> 'docker ps'"
echo ""
echo "Live monitoring:"
echo "  sudo tcpdump -i $GRE_INTERFACE -n"
if [[ -n "$TRAFFIC_HOST_VPC_IP" ]]; then
    echo "  sudo tcpdump -i eth1 -n host $TRAFFIC_HOST_VPC_IP"
fi
