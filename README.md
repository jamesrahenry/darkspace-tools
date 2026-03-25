# darkspace-tools

A modular toolkit for monitoring, analyzing, and interacting with darkspace (unused IP) traffic
using GRE tunnels, iptables-based flow counting, Suricata IDS, and T-Pot honeypots.

## What is Darkspace?

Unused IP address ranges should receive **zero** legitimate traffic. Anything that arrives
is inherently suspicious — scanners, botnets, worms, backscatter from DDoS attacks.
Monitoring this "darkspace" gives you a low-noise, high-signal view of malicious activity
on the internet.

## Deployment Profiles

Choose the level of visibility you need:

| Profile | What You Get | Infra Needed | RAM | Monthly Cost* |
|---------|-------------|-------------|-----|--------------|
| **netflow** | GRE tunnel + kernel packet counters | Router only | 512MB | ~$6 |
| **ids** | + Suricata IDS alerts | Router + Traffic-Host | 2GB | ~$24 |
| **honeypot-lite** | + Selected honeypot containers | Router + Traffic-Host | 2GB | ~$24 |
| **honeypot-full** | + Full T-Pot platform + ELK stack | Router + Traffic-Host | 4GB+ | ~$30 |

*Estimates based on DigitalOcean pricing. Adaptable to AWS, GCP, Hetzner, or bare metal.

## Architecture

```
                        GRE Tunnel (IP proto 47)
                   ┌────────────────────────────────┐
                   │                                │
┌──────────────┐   │   ┌──────────┐    VPC    ┌─────────────┐
│  Darkspace   │───┘   │  Router  │◄────────►│Traffic-Host  │
│  Source      │       │          │  private  │             │
│              │       │ NAT/FWD  │  network  │ Honeypot    │
└──────────────┘       │ Counting │           │ Suricata    │
                       └──────────┘           │ Containers  │
                                              └─────────────┘
```

**Key features:**
- **Policy routing** ensures reply packets preserve the original target IP as source
- **VPC isolation** keeps the honeypot off the public internet
- **Modular profiles** — deploy only what you need
- **Ansible automation** for reproducible deployments
- **Makefile interface** for common operations

## Quick Start

```bash
# 1. Clone
git clone https://github.com/jamesrahenry/darkspace-tools.git
cd darkspace-tools

# 2. Bootstrap your router
sudo bash scripts/bootstrap-router.sh

# 3. Interactive setup (picks profile, configures IPs)
sudo bash scripts/setup.sh

# 4. Deploy
sudo bash scripts/deploy.sh

# 5. Verify
make diagnose
```

See [docs/QUICKSTART.md](docs/QUICKSTART.md) for the full 5-minute guide.

## What You Can Do

### With any profile:
- Count packets by source network, destination IP, protocol, port
- Capture traffic with tcpdump for offline analysis
- Detect scanning campaigns in real-time

### With ids or higher:
- Get Suricata IDS alerts on darkspace traffic
- Match against ET Open / ET Pro rulesets
- Export alerts in EVE JSON format

### With honeypot-lite or higher:
- Capture SSH/Telnet credentials and attacker commands (Cowrie)
- Collect malware samples (Dionaea)
- Log SMTP spam attempts (Mailoney)

### With honeypot-full:
- All of the above plus Kibana dashboards
- Elasticsearch for full-text search across all logs
- EWSPoster for sharing with Deutsche Telekom's threat intel

## Documentation

| Guide | Description |
|-------|------------|
| [QUICKSTART](docs/QUICKSTART.md) | 5-minute getting started guide |
| [SETUP](docs/SETUP.md) | Detailed step-by-step setup |
| [ARCHITECTURE](docs/ARCHITECTURE.md) | Topology, traffic flow, policy routing |
| [NETFLOW_FORWARDING](docs/NETFLOW_FORWARDING.md) | GRE tunnels, iptables counting, ipset management |
| [REPORTING](docs/REPORTING.md) | Data export per profile, SIEM integration |
| [ANALYSIS](docs/ANALYSIS.md) | Packet capture, IOC extraction, threat intel |
| [MONITORING](docs/MONITORING.md) | Health checks, alerting, log rotation |
| [TEARDOWN](docs/TEARDOWN.md) | Data export, infrastructure destruction |
| [TROUBLESHOOTING](docs/TROUBLESHOOTING.md) | Common issues and fixes |
| [SECURITY](docs/SECURITY.md) | Threat model, hardening, incident response |
| [CLOUD_PROVIDERS](docs/CLOUD_PROVIDERS.md) | AWS, GCP, Hetzner, bare-metal adaptation |
| [UPGRADING](docs/UPGRADING.md) | Profile changes, adding services, updates |

## Repository Layout

```
├── ansible/                    # Ansible playbooks and templates
│   ├── deploy-all.yml          # Main orchestrator (profile-aware)
│   ├── deploy-router.yml       # GRE tunnel + NAT + policy routing
│   ├── deploy-traffic-host.yml # Target IP binding + routing
│   ├── deploy-honeypot.yml     # Docker + T-Pot/containers
│   ├── bootstrap-system.yml    # System hardening
│   ├── dynamic-inventory.py    # Auto-discover traffic-hosts
│   └── templates/              # Jinja2 templates for configs
├── scripts/                    # Shell scripts
│   ├── setup.sh                # Interactive setup wizard
│   ├── deploy.sh               # Main deployment script
│   ├── teardown.sh             # Destroy infrastructure
│   ├── diagnose.sh             # 9-category diagnostics
│   └── configure-*.sh          # Component-specific setup
├── configs/                    # Configuration files
├── systemd/                    # Systemd service units
├── examples/                   # Example configs (safe to commit)
├── docs/                       # Full documentation
└── Makefile                    # Common operations
```

## Make Targets

```
make help         Show all targets
make setup        Interactive setup wizard
make deploy       Deploy with selected profile (PROFILE=netflow|ids|honeypot-lite|honeypot-full)
make teardown     Destroy infrastructure
make diagnose     Run all diagnostics
make status       Quick health check
make lint         Shellcheck + ansible-lint
make check-sanitization  Verify no real IPs in codebase
```

## Prerequisites

- **OS:** Debian 12+ or Ubuntu 22.04+ on the router
- **Access:** Root or sudo on the router machine
- **GRE source:** A darkspace traffic source forwarding via GRE
- **Cloud (optional):** DigitalOcean account + `doctl` CLI (for ids/honeypot profiles)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
