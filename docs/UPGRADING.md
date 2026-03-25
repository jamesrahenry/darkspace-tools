# Upgrading and Profile Changes

How to upgrade between profiles, add/remove services, and update components.

## Profile Upgrade Paths

```
netflow ──► ids ──► honeypot-lite ──► honeypot-full
   │          │          │                  │
   │          │          │                  │
   ▼          ▼          ▼                  ▼
Router     + Traffic   + Selected       + Full T-Pot
only         Host +      Honeypot         + ELK
             Suricata    Containers        Stack
```

Each profile is a superset of the previous one.

## Upgrading to a Higher Profile

### netflow → ids

**What changes:** Creates a traffic-host droplet, installs Docker + Suricata.

```bash
# Update your config
# Edit .env or re-run setup:
bash scripts/setup.sh  # Select profile 2 (ids)

# Deploy the traffic-host
bash scripts/deploy.sh
```

### ids → honeypot-lite

**What changes:** Adds selected honeypot containers alongside Suricata.

```bash
# Re-run setup, select profile 3
bash scripts/setup.sh

# Redeploy (will add containers to existing traffic-host)
bash scripts/deploy.sh
```

### honeypot-lite → honeypot-full

**What changes:** Replaces lightweight compose with full T-Pot (ELK stack, all honeypots).

```bash
# Re-run setup, select profile 4
bash scripts/setup.sh

# This will replace the docker-compose on the traffic-host
bash scripts/deploy.sh

# Note: You may need a larger droplet for honeypot-full (4GB+ RAM recommended)
# Resize first if needed:
doctl compute droplet-action resize <droplet-id> --size s-2vcpu-4gb --wait
```

## Downgrading

### honeypot-full → honeypot-lite

```bash
# Stop full T-Pot
ssh root@<vpc-ip> 'systemctl stop tpot'
ssh root@<vpc-ip> 'docker compose -f /opt/tpot/docker-compose.yml down -v'

# Re-run setup with profile 3
bash scripts/setup.sh

# Redeploy (installs lightweight compose)
bash scripts/deploy.sh
```

### Any profile → netflow

```bash
# Destroy traffic-host
doctl compute droplet list | grep traffic-host
doctl compute droplet delete <id> --force

# Clean router NAT rules
iptables -t nat -F PREROUTING
iptables -t nat -F POSTROUTING
iptables -F FORWARD
iptables-save > /etc/iptables/rules.v4

# Re-run setup with profile 1
bash scripts/setup.sh
```

## Adding Individual Services

### Add a Honeypot Container

Edit the Docker Compose file on the traffic-host:

```bash
ssh root@<vpc-ip>

# Edit compose file
nano /opt/tpot/docker-compose.yml

# Add your service (example: adding Mailoney)
# services:
#   mailoney:
#     image: "ghcr.io/telekom-security/mailoney:24.04.1"
#     restart: always
#     ports:
#       - "${TARGET_IP}:25:25"

# Restart
systemctl restart tpot
```

Or use the Makefile:

```bash
# Add honeytrap service
make add-service SERVICE=honeytrap
```

### Add NAT Rules for New Ports

If your new honeypot listens on additional ports, add DNAT rules on the router:

```bash
# On router
TARGET_IP="198.51.100.50"
TRAFFIC_HOST_VPC="10.100.0.x"

iptables -t nat -A PREROUTING -i darkspace-gre -d "$TARGET_IP" -p tcp --dport 25 -j DNAT --to-destination "$TRAFFIC_HOST_VPC"
iptables -A FORWARD -i darkspace-gre -d "$TRAFFIC_HOST_VPC" -p tcp --dport 25 -j ACCEPT

# Save
iptables-save > /etc/iptables/rules.v4
```

## Updating Components

### Update T-Pot Containers

```bash
ssh root@<vpc-ip> 'cd /opt/tpot && docker compose pull && systemctl restart tpot'
```

### Update Suricata Rules

```bash
ssh root@<vpc-ip> 'docker exec suricata suricata-update && docker restart suricata'
```

### Update System Packages

```bash
# Router
apt update && apt upgrade -y

# Traffic-host
ssh root@<vpc-ip> 'apt update && apt upgrade -y'
```

### Update darkspace-tools

```bash
cd /path/to/darkspace-tools
git pull origin main

# Review changes
git log --oneline -10

# Re-deploy with updated playbooks
make deploy
```

## Data Preservation During Upgrades

### What's Preserved

- GRE tunnel configuration (on router, survives traffic-host changes)
- iptables rules (on router)
- ipset data (on router)
- Ansible vault (local)
- Configuration files (.env, inventory)

### What May Be Lost

- Docker volumes (when switching compose files)
- Elasticsearch data (when downgrading from honeypot-full)
- Container logs (when removing containers)

### Export Before Major Changes

```bash
# Export Elasticsearch
ssh -L 9200:<vpc-ip>:9200 root@<router-ip> &
curl -sk -u elastic:<password> 'https://localhost:9200/_cat/indices?h=index' | while read idx; do
  curl -sk -u elastic:<password> "https://localhost:9200/${idx}/_search?scroll=1m&size=1000" > "backup-${idx}.json"
done

# Export container logs
for c in cowrie dionaea honeytrap suricata; do
  ssh root@<vpc-ip> "docker logs $c" > "backup-${c}.log" 2>&1
done

# Export Suricata alerts
scp root@<vpc-ip>:/var/log/suricata/eve.json ./backup-eve.json
```

## Version Compatibility

| darkspace-tools | T-Pot | Docker Compose | Debian | Ubuntu |
|----------------|-------|---------------|--------|--------|
| 1.0.x | 24.04.1 | v2 | 12+ | 22.04+ |

When upgrading T-Pot versions, check the [T-Pot release notes](https://github.com/telekom-security/tpotce/releases) for breaking changes in container names, ports, or configuration format.
