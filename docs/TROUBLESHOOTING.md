# Troubleshooting

Common issues and their solutions.

## GRE Tunnel Issues

### Tunnel Not Coming Up

**Symptoms:** `ip link show darkspace-gre` shows no interface or state DOWN.

```bash
# Check if GRE kernel module is loaded
lsmod | grep ip_gre
# If not: modprobe ip_gre

# Verify tunnel configuration
ip tunnel show

# Check if remote host is reachable (not through tunnel)
ping <darkspace-host-ip>

# Check if GRE protocol (47) is allowed by firewall
iptables -L INPUT -n | grep gre
# If not: iptables -A INPUT -p gre -j ACCEPT
```

**Common causes:**
- GRE kernel module not loaded → `modprobe ip_gre`
- Firewall blocking GRE protocol → Add `iptables -A INPUT -p gre -j ACCEPT`
- Wrong remote/local IPs → Check with `ip tunnel show`
- Remote host firewall blocking GRE → Coordinate with remote admin

### Tunnel Up But No Traffic

```bash
# Watch for packets
sudo tcpdump -i darkspace-gre -n -c 10

# Check if remote end is sending
sudo tcpdump -i eth0 -n proto gre -c 10

# Verify remote end configuration matches
# Local IP here = Remote IP there (and vice versa)
ip tunnel show darkspace-gre
```

## Policy Routing Issues

### Replies Using Wrong Source IP

**Symptoms:** Return packets have source IP = VPC IP instead of target IP.

This is the most common and critical issue. The fix requires policy routing on both
the traffic-host and router.

**On traffic-host:**
```bash
# Check policy rule exists
ip rule show | grep target_replies
# Expected: from <target-ip> lookup target_replies

# Check routing table
ip route show table target_replies
# Expected: default via <router-vpc-ip> dev eth1

# Check rp_filter is disabled
sysctl net.ipv4.conf.all.rp_filter
sysctl net.ipv4.conf.dummy0.rp_filter
# Both should be 0

# Fix if missing:
ip rule add from <target-ip> lookup target_replies priority 100
ip route add default via <router-vpc-ip> dev eth1 table target_replies
sysctl -w net.ipv4.conf.all.rp_filter=0
sysctl -w net.ipv4.conf.dummy0.rp_filter=0
```

**On router:**
```bash
# Check policy rule
ip rule show | grep gre_replies
# Expected: from <target-ip> lookup gre_replies

# Check routing table
ip route show table gre_replies
# Expected: default via 192.168.240.x dev darkspace-gre

# Check SNAT rule
iptables -t nat -L POSTROUTING -n -v | grep <target-ip>

# Fix if missing:
ip rule add from <target-ip> lookup gre_replies priority 100
ip route add default via 192.168.240.2 dev darkspace-gre table gre_replies
```

### Route Table Not Found

```bash
# Check if table is defined
grep -E "gre_replies|target_replies" /etc/iproute2/rt_tables

# Add if missing
echo "200 gre_replies" >> /etc/iproute2/rt_tables    # On router
echo "100 target_replies" >> /etc/iproute2/rt_tables  # On traffic-host
```

## T-Pot / Docker Issues

### Containers Not Starting

```bash
# Check systemd service
ssh root@<vpc-ip> 'systemctl status tpot'
ssh root@<vpc-ip> 'journalctl -u tpot -n 50'

# Check Docker
ssh root@<vpc-ip> 'docker ps -a'
ssh root@<vpc-ip> 'docker compose -f /opt/tpot/docker-compose.yml logs --tail 20'

# Check disk space (common cause)
ssh root@<vpc-ip> 'df -h /'

# Check if ports are available
ssh root@<vpc-ip> 'ss -tlnp | grep -E ":22|:80|:443"'
```

### Port Conflicts

T-Pot services need to bind to the target IP. If another service is using the port:

```bash
# Check what's using a port
ssh root@<vpc-ip> 'ss -tlnp | grep ":22"'

# Common conflicts:
# - sshd on port 22 → Move SSH to port 64295 or bind to VPC IP only
# - nginx on port 80 → Stop/disable default nginx
# - exim4 on port 25 → Stop/disable: systemctl disable exim4

# Disable conflicting services
ssh root@<vpc-ip> 'systemctl disable --now nginx exim4 2>/dev/null; true'
```

### Elasticsearch Won't Start

```bash
# Check ES logs
ssh root@<vpc-ip> 'docker logs elasticsearch --tail 30'

# Common fix: vm.max_map_count too low
ssh root@<vpc-ip> 'sysctl -w vm.max_map_count=262144'
ssh root@<vpc-ip> 'echo "vm.max_map_count = 262144" >> /etc/sysctl.conf'

# Restart
ssh root@<vpc-ip> 'docker restart elasticsearch'
```

## Firewall Issues

### UFW Blocking GRE

```bash
# Check if GRE is allowed
ufw status verbose

# GRE is protocol 47, not a port. Standard UFW rules don't cover it.
# It must be in /etc/ufw/before.rules:
grep -i gre /etc/ufw/before.rules

# Fix: Re-run firewall configuration
sudo bash scripts/configure-router-firewall.sh
```

### VPC Traffic Blocked

```bash
# Ensure VPC network is allowed
ufw status | grep "10.100"

# Add if missing (adjust network to match your VPC)
ufw allow from 10.100.0.0/20 comment 'VPC network'
```

## VPC Connectivity Issues

### Cannot Reach Traffic-Host

```bash
# Verify traffic-host exists
doctl compute droplet list | grep traffic-host

# Check it's in the same VPC
doctl compute droplet get <id> --format PrivateIPv4,VpcUUID

# Ping via VPC
ping <traffic-host-vpc-ip>

# Check router has VPC interface
ip addr show eth1

# Verify VPC interface is up
ip link set eth1 up
```

### Traffic-Host Has No Internet

```bash
# Check MASQUERADE rule on router
iptables -t nat -L POSTROUTING -n | grep MASQUERADE

# Fix if missing
VPC_NET=$(ip addr show eth1 | grep "inet " | awk '{print $2}')
iptables -t nat -A POSTROUTING -s "$VPC_NET" -o eth0 -j MASQUERADE
```

## Diagnostic Commands Reference

```bash
# === Router ===
ip tunnel show                           # GRE tunnel details
ip rule show                             # Policy routing rules
ip route show table gre_replies          # GRE reply routes
iptables -t nat -L -n -v                 # NAT rules with counters
iptables -L FORWARD -n -v               # Forwarding rules
iptables -t raw -L NETFLOW -n -v        # Netflow counters
tcpdump -i darkspace-gre -n             # Live GRE traffic
tcpdump -i eth1 -n                      # Live VPC traffic

# === Traffic-Host ===
ip addr show dummy0                      # Target IP binding
ip rule show                             # Policy routing
ip route show table target_replies       # Reply routes
docker ps                                # Container status
docker stats --no-stream                 # Resource usage
journalctl -u tpot -f                   # T-Pot logs
ss -tlnp                                # Listening ports
```

## Getting Help

1. Run `make diagnose` and save the output
2. Check the specific section above for your symptom
3. Review `journalctl` and `docker logs` for error messages
4. Check [Architecture](ARCHITECTURE.md) to understand expected traffic flow
