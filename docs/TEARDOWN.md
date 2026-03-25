# Teardown Guide

How to safely shut down and destroy darkspace-tools infrastructure.

## Quick Teardown

```bash
# Destroy everything (interactive, requires typing 'yes')
make teardown

# Or directly:
sudo bash scripts/teardown.sh
```

## Data Export Before Teardown

**Always export your data before destroying infrastructure.**

### Export Suricata Alerts

```bash
ssh root@<traffic-host-vpc-ip> 'cat /var/log/suricata/eve.json' > suricata-export-$(date +%Y%m%d).json
ssh root@<traffic-host-vpc-ip> 'cat /var/log/suricata/fast.log' > suricata-fast-$(date +%Y%m%d).log
```

### Export Cowrie Logs

```bash
ssh root@<traffic-host-vpc-ip> 'docker logs cowrie' > cowrie-export-$(date +%Y%m%d).log 2>&1
```

### Export Dionaea Data

```bash
# Captured malware samples
scp root@<traffic-host-vpc-ip>:/opt/dionaea/var/dionaea/binaries/* ./malware-samples/

# Connection database
scp root@<traffic-host-vpc-ip>:/opt/dionaea/var/dionaea/dionaea.sqlite ./
```

### Export Elasticsearch Data (honeypot-full)

```bash
# SSH tunnel
ssh -L 9200:<traffic-host-vpc-ip>:9200 root@<router-ip> &

# Export all indices
for index in $(curl -sk -u elastic:<password> 'https://localhost:9200/_cat/indices?h=index' | grep -v '^\.' ); do
  curl -sk -u elastic:<password> "https://localhost:9200/${index}/_search?scroll=1m&size=1000" > "export-${index}.json"
done
```

## What Teardown Does

1. **Destroys traffic-host droplets** via DigitalOcean API
2. **Removes GRE tunnel** (ip tunnel del + netplan cleanup)
3. **Cleans iptables** (flushes NAT PREROUTING, POSTROUTING, FORWARD chains)
4. **Removes routing** (policy rules, routing tables 200/gre_replies)
5. **Deletes config files** (inventory, .env, current-config.env)

## What Teardown Does NOT Remove

- **VPC** — must be deleted manually
- **SSH keys** in DigitalOcean — must be removed manually
- **Ansible vault** (ansible/vault.yml) — kept intentionally
- **The git repo** — kept for future deployments
- **System packages** installed by bootstrap

## Manual Cleanup

### Delete VPC

```bash
doctl vpcs list
doctl vpcs delete <vpc-id>
```

### Remove SSH Keys from DigitalOcean

```bash
doctl compute ssh-key list
doctl compute ssh-key delete <key-id>
```

### Remove Local SSH Keys

```bash
rm -f ~/.ssh/id_darkspace ~/.ssh/id_darkspace.pub
```

### Remove Vault Password

```bash
rm -f ~/.vault_pass
```

## Partial Teardown

### Remove Only Traffic-Host (Keep Router)

```bash
# Delete droplet
doctl compute droplet list | grep traffic-host
doctl compute droplet delete <id> --force

# Clean router NAT rules
iptables -t nat -F PREROUTING
iptables -t nat -F POSTROUTING
iptables -F FORWARD
iptables-save > /etc/iptables/rules.v4

# Remove traffic-host inventory
rm -f ansible/traffic-host-inventory.yml
```

### Remove Only Containers (Keep Infrastructure)

```bash
ssh root@<traffic-host-vpc-ip> 'systemctl stop tpot'
ssh root@<traffic-host-vpc-ip> 'docker compose -f /opt/tpot/docker-compose.yml down -v'
```

### Downgrade Profile

See [Upgrading](UPGRADING.md) for profile change procedures.

## Cost Management

### Estimate Running Costs

```bash
# List running droplets with size/cost
doctl compute droplet list --format Name,Size,Region,Status
```

| Size | Monthly Cost | Use For |
|------|-------------|---------|
| s-1vcpu-1gb | ~$6 | Router (all profiles) |
| s-2vcpu-2gb | ~$18 | Traffic-host (ids, honeypot-lite) |
| s-2vcpu-4gb | ~$24 | Traffic-host (honeypot-full) |

### Reduce Costs

- **Resize droplets** during low-traffic periods
- **Snapshot and destroy** traffic-host when not actively monitoring
- **Use `netflow` profile** when you only need traffic counting (~$6-12/month)
- **Schedule deployments** for specific monitoring windows

### Snapshot Before Destroy

```bash
# Create snapshot (preserves data)
doctl compute droplet-action snapshot <droplet-id> --snapshot-name "darkspace-backup-$(date +%Y%m%d)"

# List snapshots
doctl compute snapshot list

# Restore from snapshot later
doctl compute droplet create traffic-host-01 --image <snapshot-id> --size s-2vcpu-2gb --region tor1
```
