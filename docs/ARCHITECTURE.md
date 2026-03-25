# Architecture

## Overview

Darkspace Tools deploys a three-tier network infrastructure that captures and analyzes traffic addressed to
"darkspace" IP addresses — unused IP space that receives unsolicited traffic from scanners, botnets, and
other malicious sources.

Traffic arrives via a **GRE tunnel** and is routed through a **VPC-isolated network** to instrumented
**monitoring/honeypot hosts** that capture, log, and analyze the traffic.

## Deployment Profiles

```
┌─────────────────────────────────────────────────────────────────────┐
│ Profile         │ Components              │ What You Get            │
├─────────────────┼─────────────────────────┼─────────────────────────┤
│ netflow         │ Router only             │ GRE tunnel + iptables   │
│                 │                         │ traffic counting        │
├─────────────────┼─────────────────────────┼─────────────────────────┤
│ ids             │ Router + Traffic-Host   │ Above + Suricata IDS    │
│                 │ + Suricata              │                         │
├─────────────────┼─────────────────────────┼─────────────────────────┤
│ honeypot-lite   │ Router + Traffic-Host   │ Above + selected        │
│                 │ + selected containers   │ honeypot services       │
├─────────────────┼─────────────────────────┼─────────────────────────┤
│ honeypot-full   │ Router + Traffic-Host   │ Above + full T-Pot      │
│                 │ + T-Pot + ELK stack     │ with Kibana dashboards  │
└─────────────────┴─────────────────────────┴─────────────────────────┘
```

## Network Topology

### All Profiles

```
                    ┌──────────────────┐
                    │  Darkspace Host  │
                    │  (GRE endpoint)  │
                    │  203.0.113.10*   │
                    └────────┬─────────┘
                             │ GRE Tunnel
                             │ (IP protocol 47)
                    ┌────────┴─────────┐
                    │     Router       │
                    │  (Public IP)     │
                    │                  │
                    │  eth0: public    │
                    │  darkspace-gre:  │
                    │   192.168.240.1  │
                    │  eth1: VPC       │
                    │   10.100.0.2*    │
                    └────────┬─────────┘
                             │ VPC Network
                             │ (10.100.0.0/20*)
                    ┌────────┴─────────┐
                    │  Traffic-Host    │
                    │  (VPC only)      │
                    │                  │
                    │  eth1: VPC       │
                    │   10.100.0.5*    │
                    │  dummy0: target  │
                    │   198.51.100.50* │
                    │                  │
                    │  [Honeypot/IDS]  │
                    └──────────────────┘

  * RFC 5737 example IPs — replace with your actual addresses
```

### Netflow Profile (Router Only)

```
  Darkspace ──GRE──▶ Router
                       │
                       ├─ iptables raw table: NETFLOW chain
                       ├─ ipset: darkspace-nets, honeypot-ips
                       └─ Packet counting per source/dest network
```

## Traffic Flow

### Inbound Path (Internet → Honeypot)

```
1. Darkspace host sends GRE-encapsulated packet
   src: <attacker>  dst: 198.51.100.50  (inside GRE)

2. Router receives on darkspace-gre interface
   → Decapsulates GRE

3. Router applies DNAT:
   dst: 198.51.100.50 → 10.100.0.5 (traffic-host VPC IP)

4. Router forwards via VPC (eth1 → eth1)

5. Traffic-host receives packet
   → Services listening on dummy0 (198.51.100.50) respond
```

### Outbound Path (Honeypot → Internet)

This is the critical path that requires **policy routing** to work correctly:

```
1. Honeypot service generates reply
   src: 198.51.100.50  dst: <attacker>

2. Traffic-host kernel selects source IP from dummy0 binding:
   src = 198.51.100.50 ✓

3. Policy routing on traffic-host:
   Rule: "from 198.51.100.50 lookup target_replies"
   Route: default via 10.100.0.2 (router) through eth1

4. Router receives reply with src = 198.51.100.50

5. Policy routing on router:
   Rule: "from 198.51.100.50 lookup gre_replies"
   Route: default via darkspace-gre interface

6. SNAT preserves source IP (198.51.100.50)

7. Packet sent through GRE tunnel to darkspace host

8. Attacker receives reply from 198.51.100.50 ✓
   (Honeypot appears as a real host)
```

### Why Policy Routing is Required

Without policy routing, reply packets would use the VPC IP (10.100.0.x) as their source
address instead of the target IP (198.51.100.50). This breaks the honeypot illusion — attackers
would see replies from an unexpected IP.

The solution uses two custom routing tables:

| Table | Host | Number | Rule |
|-------|------|--------|------|
| `target_replies` | Traffic-Host | 100 | `from <target_ip> lookup target_replies` |
| `gre_replies` | Router | 200 | `from <target_ip> lookup gre_replies` |

## Port Mapping

### Honeypot Services (bound to target IP)

| Service | Port(s) | Protocol | Profile |
|---------|---------|----------|---------|
| Cowrie | 22, 23 | SSH, Telnet | honeypot-lite, honeypot-full |
| Dionaea | 21, 80, 135, 443, 445, 1433, 3306, 5432 + more | Multi-protocol | honeypot-lite, honeypot-full |
| Honeytrap | 110, 143, 993, 995 | POP3, IMAP | honeypot-lite, honeypot-full |
| Mailoney | 25 | SMTP | honeypot-lite, honeypot-full |
| Suricata | passive | IDS (all traffic) | ids, honeypot-lite, honeypot-full |

### Management Services (bound to VPC IP, honeypot-full only)

| Service | Port | Purpose |
|---------|------|---------|
| Elasticsearch | 9200 | Data storage and search |
| Kibana | 5601 | Visualization dashboards |
| Nginx | 64297 | T-Pot web interface |

## Component Dependencies

```
bootstrap-system.yml          (base system hardening)
  │
  ▼
deploy-router.yml             (GRE tunnel + NAT) ◄── ALL profiles need this
  │
  ├──▶ configure-netflow-monitoring.sh  (netflow profile stops here)
  │
  ▼
deploy-traffic-host.yml       (target IP binding + policy routing)
  │
  ├──▶ Suricata container     (ids profile stops here)
  │
  ├──▶ Selected containers    (honeypot-lite profile stops here)
  │
  ▼
deploy-honeypot.yml           (full T-Pot + ELK stack)
                              (honeypot-full profile)
```

## Network Security Model

- **Honeypot services** bind **only** to the target IP (198.51.100.50)
- **Management services** (Kibana, Elasticsearch) bind **only** to the VPC IP
- The traffic-host has **no public IP** — accessible only through VPC
- UFW firewall on router allows only GRE protocol and VPC traffic
- fail2ban protects SSH on all hosts
- Ansible vault encrypts all passwords

## Cost Estimate (DigitalOcean)

| Profile | Droplets | Monthly Cost |
|---------|----------|-------------|
| netflow | 1 (router) | ~$12 |
| ids | 2 (router + traffic-host) | ~$36 |
| honeypot-lite | 2 (router + traffic-host) | ~$36 |
| honeypot-full | 2 (router + traffic-host, larger) | ~$48 |

Costs vary by region and droplet size. The traffic-host needs at least 2 vCPUs / 2GB RAM
for the full T-Pot deployment.
