# Security

Security model, hardening practices, and risk assessment for darkspace-tools.

## Threat Model

Running a honeypot means **intentionally attracting malicious traffic**. Understand the risks:

| Threat | Mitigation |
|--------|-----------|
| Attacker pivots from honeypot to internal network | VPC isolation — honeypot has no route to your other systems |
| Honeypot container escape | Docker + unprivileged user + minimal capabilities |
| Credential exposure in git | Ansible Vault for secrets; .gitignore for config files |
| SSH brute-force on management ports | fail2ban + key-only auth + non-standard port |
| GRE tunnel abuse | IP-locked tunnel (only accepts from configured remote) |
| Darkspace host compromise | Router only forwards, never stores sensitive data |

## Network Isolation

### VPC Architecture

```
Internet
    │
    ▼
┌─────────┐     VPC (private)     ┌──────────────┐
│  Router  │◄────────────────────►│ Traffic-Host  │
│ (public) │   10.100.0.0/20      │ (no public IP)│
│          │                      │               │
│ eth0: public                    │ eth0: VPC only │
│ eth1: VPC                       └───────────────┘
└─────────┘
```

- **Traffic-host has no public IP** — accessible only through the router via VPC
- **Router is the sole entry point** — all management goes through it
- **GRE tunnel is IP-locked** — only accepts encapsulated packets from the configured remote
- **No east-west exposure** — honeypot cannot reach other VPC workloads (deploy in a dedicated VPC)

### Firewall Rules (Router)

```
UFW defaults: deny incoming, allow outgoing
Allowed inbound:
  - SSH (port 22 or custom) from your management IP
  - GRE (protocol 47) from darkspace source IP only
  - VPC subnet for inter-node communication
```

### Firewall Rules (Traffic-Host)

```
UFW defaults: deny incoming, allow outgoing
Allowed inbound:
  - SSH from VPC subnet only (router)
  - Honeypot ports from VPC subnet only (forwarded by router)
```

## Secret Management

### Ansible Vault

All passwords and sensitive configuration are stored in an encrypted Ansible Vault file.

```bash
# Create vault
ansible-vault create ansible/vault.yml

# Required vault variables:
vault_tpot_web_password: <kibana-web-password>
vault_tpot_admin_password: <admin-password>
vault_es_password: <elasticsearch-password>

# Encrypt with a password file
echo "your-vault-password" > ~/.vault_pass
chmod 600 ~/.vault_pass
```

### What Should NEVER Be in Git

The `.gitignore` prevents these from being committed:

- `ansible/vault.yml` (encrypted secrets)
- `ansible/inventory.yml` (contains real IPs)
- `.env` / `*.env` (environment config)
- `~/.vault_pass` (vault password)
- SSH private keys
- `current-config.env` (deployment state)

### Rotating Secrets

```bash
# Re-encrypt vault with new password
ansible-vault rekey ansible/vault.yml

# Change T-Pot web password
ansible-vault edit ansible/vault.yml
# Update vault_tpot_web_password
# Redeploy: make deploy
```

## SSH Hardening

### Router

The bootstrap playbook configures:

- **Key-only authentication** (password auth disabled)
- **Root login via key only** (`PermitRootLogin prohibit-password`)
- **fail2ban** watching SSH logs (5 attempts → 10-minute ban)
- **Non-standard port** (optional, configure in inventory)

### Traffic-Host

- **No public SSH** — only reachable via VPC from router
- **Key-only authentication**
- **Access via SSH jump**: `ssh -J root@<router-ip> root@<traffic-host-vpc-ip>`

### SSH Config Example

```
# ~/.ssh/config
Host darkspace-router
    HostName <router-public-ip>
    User root
    IdentityFile ~/.ssh/id_darkspace

Host darkspace-traffic
    HostName <traffic-host-vpc-ip>
    User root
    IdentityFile ~/.ssh/id_darkspace
    ProxyJump darkspace-router
```

## Docker Security

### Container Isolation

- Containers run as **non-root users** where possible
- **No `--privileged`** flag
- **Read-only filesystems** where supported
- **Resource limits** via Docker Compose `mem_limit` / `cpus`
- **No host networking** — containers bind to specific IPs only

### Image Sources

| Container | Image Source |
|-----------|-------------|
| Cowrie | Official Docker Hub (`cowrie/cowrie`) |
| Dionaea | T-Pot community image |
| Suricata | Official OISF image |
| Elasticsearch | Official Elastic image |
| Kibana | Official Elastic image |

Update images regularly:

```bash
ssh root@<vpc-ip> 'docker compose -f /opt/tpot/docker-compose.yml pull'
ssh root@<vpc-ip> 'systemctl restart tpot'
```

## Risk Assessment

### Low Risk (netflow profile)

- No honeypot services exposed
- Only kernel-level packet counting
- Attack surface: SSH on router only

### Medium Risk (ids, honeypot-lite)

- Suricata is passive (no exposed services)
- Cowrie/Dionaea containers are sandboxed
- Attack surface: SSH + honeypot ports (contained)

### Higher Risk (honeypot-full)

- Full T-Pot with Elasticsearch exposed on VPC
- More containers = larger attack surface
- Elasticsearch has had historical CVEs
- Mitigations: VPC isolation, regular updates, monitoring

### Recommendations

1. **Dedicated VPC** — don't share with production workloads
2. **Regular updates** — `apt update && apt upgrade` on a schedule
3. **Monitor resource usage** — compromised containers may mine crypto
4. **Review logs** — check for unexpected outbound connections
5. **Rotate credentials** — change vault passwords periodically
6. **Limit SSH access** — restrict to known management IPs
7. **Back up data, not config** — export analysis data, keep configs reproducible

## Incident Response

If you suspect a container has been compromised:

```bash
# 1. Isolate: Stop the container
ssh root@<vpc-ip> 'docker stop <container-name>'

# 2. Preserve: Export for analysis
ssh root@<vpc-ip> 'docker export <container-name> > /tmp/compromised-container.tar'

# 3. Check: Look for unexpected processes/connections
ssh root@<vpc-ip> 'docker top <container-name>'
ssh root@<vpc-ip> 'docker exec <container-name> ss -tlnp'

# 4. Clean: Remove and redeploy
ssh root@<vpc-ip> 'docker rm <container-name>'
ssh root@<vpc-ip> 'systemctl restart tpot'

# 5. Review: Check other containers
ssh root@<vpc-ip> 'docker ps -a'
ssh root@<vpc-ip> 'docker stats --no-stream'
```
