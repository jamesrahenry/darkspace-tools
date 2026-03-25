# Monitoring

Operational health monitoring for darkspace-tools deployments.

## Quick Status Check

```bash
# One-liner status
make status

# Full diagnostics
make diagnose
```

## Per-Component Health Checks

### GRE Tunnel

```bash
# Check interface exists and is UP
ip link show darkspace-gre

# Check tunnel has IP assigned
ip addr show darkspace-gre | grep "inet "

# Ping remote endpoint
ping -c 3 192.168.240.2

# Check packet flow (should see RX/TX incrementing)
ip -s link show darkspace-gre

# Run the status script (installed by deploy)
/usr/local/bin/gre-tunnel-status.sh
```

### Router Health

```bash
# IP forwarding enabled
sysctl net.ipv4.ip_forward

# iptables rules loaded
iptables -t nat -L PREROUTING -n | grep DNAT
iptables -L FORWARD -n | grep darkspace-gre

# Policy routing active
ip rule show | grep gre_replies
ip route show table gre_replies

# Packet counters (non-zero = traffic flowing)
iptables -t nat -L PREROUTING -n -v | head -5
```

### Traffic-Host Health (ids, honeypot-lite, honeypot-full)

```bash
# From router, test VPC connectivity
ping -c 3 <traffic-host-vpc-ip>

# SSH and check target IP
ssh root@<traffic-host-vpc-ip> 'ip addr show dummy0 | grep "inet "'

# Check policy routing
ssh root@<traffic-host-vpc-ip> 'ip rule show | grep target_replies'

# Check default route (should go to router)
ssh root@<traffic-host-vpc-ip> 'ip route show default'

# Run monitoring script (if honeypot deployed)
ssh root@<traffic-host-vpc-ip> '/usr/local/bin/monitor-tpot.sh'
```

### Container Health (honeypot-lite, honeypot-full)

```bash
# List running containers
ssh root@<traffic-host-vpc-ip> 'docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'

# Check for crashed containers
ssh root@<traffic-host-vpc-ip> 'docker ps -a --filter "status=exited" --format "{{.Names}}: {{.Status}}"'

# Restart a container
ssh root@<traffic-host-vpc-ip> 'docker restart cowrie'

# View container logs
ssh root@<traffic-host-vpc-ip> 'docker logs --tail 20 cowrie'

# Systemd service status
ssh root@<traffic-host-vpc-ip> 'systemctl status tpot'
```

## Automated Monitoring

### Cron-Based Health Check

Add to root's crontab on the router:

```bash
# /etc/cron.d/darkspace-monitor
*/5 * * * * root /usr/local/bin/darkspace-health-check.sh >> /var/log/darkspace-health.log 2>&1
```

Create `/usr/local/bin/darkspace-health-check.sh`:

```bash
#!/bin/bash
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
ALERTS=""

# Check GRE tunnel
if ! ip link show darkspace-gre >/dev/null 2>&1; then
    ALERTS="${ALERTS}[CRITICAL] GRE tunnel down\n"
fi

# Check traffic-host reachability
VPC_IP=$(ip route show | grep "198.51.100.50" | awk '{print $3}')
if [[ -n "$VPC_IP" ]] && ! ping -c 1 -W 2 "$VPC_IP" >/dev/null 2>&1; then
    ALERTS="${ALERTS}[WARNING] Traffic-host unreachable\n"
fi

# Check disk usage on router
DISK=$(df -h / | tail -1 | awk '{print $5}' | tr -d '%')
if [[ $DISK -gt 90 ]]; then
    ALERTS="${ALERTS}[WARNING] Router disk usage: ${DISK}%\n"
fi

if [[ -n "$ALERTS" ]]; then
    echo "$TIMESTAMP - ISSUES DETECTED:"
    echo -e "$ALERTS"
else
    echo "$TIMESTAMP - All systems healthy"
fi
```

### Traffic-Host Container Watchdog

On the traffic-host:

```bash
# /etc/cron.d/container-watchdog
*/10 * * * * root docker ps -a --filter "status=exited" --format "{{.Names}}" | while read name; do docker restart "$name" 2>/dev/null; echo "$(date) Restarted $name" >> /var/log/container-restarts.log; done
```

## Resource Monitoring

### Disk Usage

```bash
# Docker volumes
ssh root@<traffic-host-vpc-ip> 'docker system df'

# Elasticsearch data
ssh root@<traffic-host-vpc-ip> 'du -sh /var/lib/docker/volumes/*elasticsearch*'

# Suricata logs
ssh root@<traffic-host-vpc-ip> 'du -sh /var/log/suricata/'
```

### Memory Usage

```bash
# Docker memory per container
ssh root@<traffic-host-vpc-ip> 'docker stats --no-stream --format "table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}"'
```

### Log Rotation

Ensure logs don't fill the disk:

```bash
# /etc/logrotate.d/darkspace
/var/log/darkspace-*.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
}

/var/log/suricata/*.log {
    daily
    rotate 14
    compress
    missingok
    postrotate
        docker kill --signal=USR2 suricata 2>/dev/null || true
    endscript
}
```

## Alerting

### Email Alerts (via msmtp)

```bash
# Install
apt install msmtp msmtp-mta

# Configure /etc/msmtprc
account default
host smtp.example.com
port 587
from darkspace@example.com
auth on
user darkspace@example.com
password <app-password>
tls on

# Send alert from health check script
echo "GRE tunnel down on $(hostname)" | mail -s "Darkspace Alert" admin@example.com
```

### Webhook Alerts (Slack/Discord)

```bash
# Add to health check script:
WEBHOOK_URL="https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
curl -X POST -H 'Content-type: application/json' \
  --data '{"text":"⚠️ Darkspace Alert: GRE tunnel down on '"$(hostname)"'"}' \
  "$WEBHOOK_URL"
```
