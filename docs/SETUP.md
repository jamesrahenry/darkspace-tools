# Detailed Setup Guide

This guide walks through every step of setting up darkspace-tools, with explanations.

## Prerequisites

### 1. Cloud Provider Account

Darkspace-tools is primarily designed for **DigitalOcean** but can be adapted for other
providers (see [Cloud Providers](CLOUD_PROVIDERS.md)).

You need:
- A DigitalOcean account
- An API token with read+write access
- At least $50/month budget for two droplets

### 2. Router Server

A Linux server that will act as the GRE tunnel endpoint and traffic router.

**Requirements:**
- Debian 12+ or Ubuntu 22.04+
- Public IP address
- Root access
- The GRE endpoint (darkspace host) must be able to reach this IP

**Recommended specs:**
- 1 vCPU, 1GB RAM (sufficient for all profiles)
- 25GB disk

### 3. GRE Tunnel Endpoint

A remote host that sends darkspace traffic via GRE tunnel to your router.
This is typically managed by a network operator or research organization.

You need from them:
- Their public IP address (the GRE remote endpoint)
- The target IP they will route traffic for
- Confirmation that GRE (IP protocol 47) is allowed between your hosts

### 4. Local Tools

Install on your workstation:

```bash
# DigitalOcean CLI
# macOS:
brew install doctl

# Linux:
snap install doctl

# Authenticate
doctl auth init
```

## Step 1: Bootstrap the Router

SSH to your router server and clone the repo:

```bash
ssh root@<your-router-ip>

git clone https://github.com/YOUR_ORG/darkspace-tools.git
cd darkspace-tools

# Install all prerequisites
sudo bash scripts/bootstrap-router.sh
```

This installs: Ansible, iptables-persistent, tcpdump, fail2ban, UFW, ipset, and more.

## Step 2: Create VPC

If you're deploying a profile that uses a traffic-host (ids, honeypot-lite, honeypot-full):

```bash
# Create a VPC in your region
doctl vpcs create \
  --name honeypot-vpc \
  --region tor1 \
  --ip-range 10.100.0.0/20 \
  --description "Darkspace tools VPC"

# Verify
doctl vpcs list
```

## Step 3: Generate SSH Keys

```bash
# Generate a deployment key
ssh-keygen -t ed25519 -C "darkspace-deploy" -f ~/.ssh/id_darkspace -N ""

# Upload to DigitalOcean
doctl compute ssh-key import darkspace-ssh-key \
  --public-key-file ~/.ssh/id_darkspace.pub
```

## Step 4: Run the Setup Wizard

```bash
sudo bash scripts/setup.sh
```

The wizard will ask for:

1. **Profile** — which deployment level you want
2. **Router public IP** — auto-detected, confirm or override
3. **Darkspace IP** — the remote GRE endpoint
4. **Target IP** — the IP address honeypot traffic is addressed to
5. **GRE parameters** — local tunnel IP and interface name (defaults are fine)
6. **DigitalOcean region** — choose closest to your darkspace host
7. **SSH key** — auto-detected or generated

Output files:
- `.env` — environment configuration
- `ansible/inventory.yml` — Ansible inventory
- `ansible/current-config.env` — deployment script configuration

## Step 5: Create Ansible Vault (honeypot profiles)

For `honeypot-lite` and `honeypot-full` profiles, you need encrypted passwords:

```bash
# Generate a vault password
openssl rand -base64 32 > ~/.vault_pass
chmod 600 ~/.vault_pass

# Copy the example vault
cp examples/vault.yml ansible/vault.yml

# Edit with real passwords (or let Ansible generate them)
vim ansible/vault.yml

# Encrypt
ansible-vault encrypt ansible/vault.yml --vault-password-file ~/.vault_pass
```

## Step 6: Deploy

```bash
sudo bash scripts/deploy.sh
```

What happens for each profile:

### netflow profile
1. Configures GRE tunnel on router
2. Sets up iptables NETFLOW rules
3. Creates ipsets for network tracking
4. Done — monitoring is active

### ids profile
1. Configures GRE tunnel on router
2. Creates traffic-host droplet in VPC
3. Binds target IP to traffic-host's dummy0 interface
4. Configures policy routing for correct source IP
5. Deploys Suricata IDS container
6. Configures NAT + forwarding on router

### honeypot-lite profile
1. Everything in `ids`, plus:
2. Deploys selected honeypot containers (Cowrie, Dionaea, etc.)
3. Containers bind to target IP

### honeypot-full profile
1. Everything in `ids`, plus:
2. Deploys full T-Pot (20+ containers)
3. Deploys ELK stack (Elasticsearch, Kibana, Logstash)
4. Deploys Nginx web interface
5. Generates encrypted credentials file

## Step 7: Verify

```bash
# Run comprehensive diagnostics
sudo bash scripts/diagnose.sh
```

The diagnostic checks:
1. GRE tunnel status
2. VPC connectivity
3. Routing tables and policy rules
4. NAT rules
5. FORWARD rules
6. Traffic-host configuration
7. End-to-end connectivity (ping, HTTP, SSH)
8. Packet counters

## Step 8: Configure Firewall (Optional)

```bash
sudo bash scripts/configure-router-firewall.sh
```

This sets up UFW with:
- SSH access allowed
- GRE protocol from darkspace host
- VPC network traffic
- All other inbound traffic denied

## Post-Deployment

### Verify GRE tunnel
```bash
# On router
ip addr show darkspace-gre
ping 192.168.240.2  # GRE remote end
```

### Check traffic flow
```bash
# Watch GRE traffic
sudo tcpdump -i darkspace-gre -n -c 10

# Watch VPC traffic
sudo tcpdump -i eth1 -n host <traffic-host-vpc-ip>
```

### Access management (honeypot-full)
```bash
# SSH tunnel for Kibana access
ssh -L 5601:<traffic-host-vpc-ip>:5601 root@<router-ip>
# Then open: http://localhost:5601

# Or for T-Pot web UI
ssh -L 64297:<traffic-host-vpc-ip>:64297 root@<router-ip>
# Then open: https://localhost:64297
```

## Updating Configuration

To change settings after deployment:

```bash
# Edit configuration
vim ansible/current-config.env

# Re-run Ansible (idempotent)
cd ansible
ansible-playbook deploy-all.yml --limit localhost -v
```

## Next Steps

- [Reporting](REPORTING.md) — analyze captured data
- [Monitoring](MONITORING.md) — set up health checks and alerts
- [Upgrading](UPGRADING.md) — change profiles or add services
