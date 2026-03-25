# Quick Start

Get darkspace traffic monitoring running in 5 minutes.

## Prerequisites

- A Linux server (Debian 12+ or Ubuntu 22.04+) with a public IP
- A remote GRE tunnel endpoint (darkspace host) that will send traffic
- Root/sudo access

**For profiles beyond `netflow`:**
- A [DigitalOcean](https://www.digitalocean.com/) account
- [doctl](https://docs.digitalocean.com/reference/doctl/how-to/install/) CLI installed
- An SSH key pair

## Which Profile Should I Use?

| I want to... | Use profile |
|---|---|
| Count and monitor darkspace traffic | `netflow` |
| Detect intrusions with Suricata IDS | `ids` |
| Capture SSH brute-force attacks | `honeypot-lite` (Cowrie) |
| Capture malware samples across protocols | `honeypot-lite` (Dionaea) |
| Run a full honeypot with dashboards | `honeypot-full` |

## 1. Bootstrap the Router

On your router server:

```bash
# Clone the repo
git clone https://github.com/YOUR_ORG/darkspace-tools.git
cd darkspace-tools

# Bootstrap system (installs Ansible, iptables, etc.)
sudo bash scripts/bootstrap-router.sh
```

## 2. Run the Setup Wizard

```bash
sudo bash scripts/setup.sh
```

The wizard will:
1. Ask you to choose a deployment profile
2. Collect your network information (IPs, GRE endpoint)
3. Configure DigitalOcean credentials (if needed)
4. Generate SSH keys (if needed)
5. Create all configuration files

## 3. Deploy

```bash
# Deploy with your selected profile
sudo bash scripts/deploy.sh

# Or use make:
make deploy PROFILE=netflow
```

## 4. Verify

```bash
# Run diagnostics
sudo bash scripts/diagnose.sh

# Or:
make diagnose
```

## 5. Access Results

**netflow profile:**
```bash
# View live GRE traffic
sudo tcpdump -i darkspace-gre -n

# View packet counters
sudo iptables -t raw -L NETFLOW -n -v

# View tracked networks
sudo ipset list darkspace-nets
```

**ids profile:**
```bash
# View Suricata alerts
ssh root@<traffic-host-vpc-ip> 'tail -f /var/log/suricata/fast.log'

# View JSON alerts
ssh root@<traffic-host-vpc-ip> 'tail -f /var/log/suricata/eve.json | python3 -m json.tool'
```

**honeypot-lite / honeypot-full:**
```bash
# Check running containers
ssh root@<traffic-host-vpc-ip> 'docker ps'

# View Cowrie SSH logs
ssh root@<traffic-host-vpc-ip> 'docker logs cowrie --tail 50'
```

**honeypot-full only:**
```
# Web UI (via SSH tunnel or VPC access)
https://<traffic-host-vpc-ip>:64297
Username: admin
Password: (see /root/.tpot-credentials.enc on traffic-host)
```

## Teardown

```bash
# Destroy everything (requires confirmation)
sudo bash scripts/teardown.sh

# Or:
make teardown
```

## Next Steps

- [Full Setup Guide](SETUP.md) — detailed step-by-step with explanations
- [Architecture](ARCHITECTURE.md) — understand the network topology
- [NetFlow Forwarding](NETFLOW_FORWARDING.md) — deep dive into GRE tunnel monitoring
- [Reporting & Analysis](REPORTING.md) — extract intelligence from captured data
- [Troubleshooting](TROUBLESHOOTING.md) — common issues and fixes
