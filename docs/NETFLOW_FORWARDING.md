# NetFlow Forwarding with GRE Tunnels

This guide explains how darkspace-tools captures and monitors network traffic using GRE tunnels
and kernel-level packet counting — the core capability behind the `netflow` profile.

## What is Darkspace Traffic?

"Darkspace" refers to unused IP address ranges that should receive no legitimate traffic.
Any packets arriving at these addresses are inherently suspicious — typically from:

- Network scanners (Shodan, Censys, Masscan)
- Botnets scanning for new targets
- Worm propagation attempts
- Backscatter from spoofed DDoS attacks
- Misconfigured systems

Monitoring darkspace provides a low-noise, high-signal view of malicious activity.

## GRE Tunnel Architecture

[Generic Routing Encapsulation (GRE)](https://tools.ietf.org/html/rfc2784) creates a
point-to-point tunnel that carries packets from the darkspace collector to your analysis
infrastructure.

```
┌──────────────────┐          GRE Tunnel          ┌──────────────────┐
│  Darkspace Host  │◄────────────────────────────►│     Router       │
│  (Collector)     │   IP Protocol 47             │  (Your server)   │
│                  │   Encapsulates any L3 packet  │                  │
│  203.0.113.10*   │                              │  <your-public-ip>│
└──────────────────┘                              └──────────────────┘
                                                    │
                                                    │ darkspace-gre interface
                                                    │ 192.168.240.1/29
                                                    │
                                                    ▼
                                              Traffic monitoring
                                              (iptables, tcpdump)
```

### Why GRE?

- **Simple**: No encryption overhead (suitable for same-organization tunnels)
- **Protocol-agnostic**: Carries any IP traffic, not just TCP/UDP
- **Low overhead**: ~24 bytes per packet
- **Widely supported**: Linux kernel built-in, no additional software needed
- **Transparent**: Original packet headers preserved inside the tunnel

## Setting Up the GRE Tunnel

### Automated (Recommended)

```bash
# The setup wizard handles GRE tunnel creation
sudo bash scripts/setup.sh
sudo bash scripts/deploy.sh
```

### Manual Setup

```bash
# Load GRE kernel module
modprobe ip_gre

# Create tunnel
ip tunnel add darkspace-gre mode gre \
  remote 203.0.113.10 \
  local <your-public-ip> \
  ttl 255

# Assign tunnel IP and bring up
ip link set darkspace-gre up
ip addr add 192.168.240.1/29 dev darkspace-gre

# Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1

# Verify
ip addr show darkspace-gre
ping 192.168.240.2  # Remote tunnel endpoint
```

### Persistent Configuration (Netplan)

For Debian 13+ / Ubuntu:

```yaml
# /etc/netplan/99-gre-tunnel.yaml
network:
  version: 2
  tunnels:
    darkspace-gre:
      mode: gre
      local: <your-public-ip>
      remote: 203.0.113.10
      addresses:
        - 192.168.240.1/29
```

```bash
sudo netplan apply
```

## NetFlow-Style Monitoring with iptables

The `netflow` profile uses **iptables raw table rules** for kernel-level traffic counting.
This is more efficient than userspace tools because counting happens at the kernel level
with zero packet copying.

### How It Works

```
Packet arrives on darkspace-gre
         │
         ▼
  iptables raw table
  PREROUTING chain
         │
         ▼
  NETFLOW chain (custom)
    ├─ Count by GRE interface (inbound/outbound)
    ├─ Count by destination (honeypot IPs)
    ├─ Count by source (darkspace networks)
    └─ RETURN (packet proceeds normally)
```

### Setup

```bash
# Automated
sudo bash scripts/configure-netflow-monitoring.sh

# View rules
sudo iptables -t raw -L NETFLOW -n -v
```

### Manual Configuration

```bash
# Create NETFLOW chain
iptables -t raw -N NETFLOW

# Count GRE inbound
iptables -t raw -A NETFLOW -i darkspace-gre \
  -m comment --comment "netflow-gre-inbound" -j RETURN

# Count GRE outbound
iptables -t raw -A NETFLOW -o darkspace-gre \
  -m comment --comment "netflow-gre-outbound" -j RETURN

# Count by destination (honeypot IPs)
iptables -t raw -A NETFLOW -m set --match-set honeypot-ips dst \
  -m comment --comment "netflow-honeypot-dst" -j RETURN

# Hook into PREROUTING
iptables -t raw -A PREROUTING -j NETFLOW
```

### Reading Counters

```bash
# View all NETFLOW counters
sudo iptables -t raw -L NETFLOW -n -v

# Example output:
# Chain NETFLOW (2 references)
#  pkts bytes target  prot opt in          out         source      destination
#  1.2M  89M  RETURN  all  --  darkspace-gre *         0.0.0.0/0   0.0.0.0/0   /* netflow-gre-inbound */
#  450K  34M  RETURN  all  --  *          darkspace-gre 0.0.0.0/0   0.0.0.0/0   /* netflow-gre-outbound */
#  890K  67M  RETURN  all  --  *          *             0.0.0.0/0   0.0.0.0/0   match-set honeypot-ips dst /* netflow-honeypot-dst */

# Reset counters
sudo iptables -t raw -Z NETFLOW
```

## ipset Management

[ipset](https://ipset.netfilter.org/) provides efficient kernel-level set matching for
network/IP groups. Darkspace-tools uses two sets:

### darkspace-nets

Tracks networks that are sending traffic through the GRE tunnel.

```bash
# Create set (hash:net = network prefixes)
ipset create darkspace-nets hash:net family inet \
  hashsize 1024 maxelem 65536 comment timeout 86400

# Add networks
ipset add darkspace-nets 192.0.2.0/24 comment "example-net-1"
ipset add darkspace-nets 198.51.100.0/24 comment "example-net-2"

# List contents
ipset list darkspace-nets

# Remove a network
ipset del darkspace-nets 192.0.2.0/24
```

### honeypot-ips

Tracks target IPs that honeypot traffic is addressed to.

```bash
# Create set (hash:ip = individual IPs)
ipset create honeypot-ips hash:ip family inet \
  hashsize 1024 maxelem 256 comment

# Add IPs
ipset add honeypot-ips 198.51.100.50 comment "primary-target"

# List
ipset list honeypot-ips
```

### Persistence

```bash
# Save (auto-done by configure-netflow-monitoring.sh)
ipset save > /etc/ipset/ipset.rules

# Restore (done by systemd service on boot)
ipset restore -exist -file /etc/ipset/ipset.rules
```

The `systemd/ipset-restore.service` ensures ipsets are loaded before iptables rules on boot.

## Live Traffic Analysis

### tcpdump on GRE Interface

```bash
# All GRE traffic
sudo tcpdump -i darkspace-gre -n

# Only TCP SYN packets (connection attempts)
sudo tcpdump -i darkspace-gre -n 'tcp[tcpflags] & tcp-syn != 0'

# Only traffic to specific port
sudo tcpdump -i darkspace-gre -n 'dst port 22'

# Save to pcap for later analysis
sudo tcpdump -i darkspace-gre -n -w /tmp/darkspace-$(date +%Y%m%d).pcap -c 10000
```

### GRE Interface Statistics

```bash
# Packet/byte counts
ip -s link show darkspace-gre

# Interface status
ip addr show darkspace-gre
```

## Optional: softflowd / nfcapd Integration

For traditional NetFlow v5/v9 export, you can add softflowd:

```bash
# Install
apt install softflowd

# Configure to watch GRE interface
softflowd -i darkspace-gre -n localhost:9995 -v 9

# Install nfcapd for collection
apt install nfdump

# Start collector
nfcapd -l /var/cache/nfdump -p 9995 -D

# Query flows
nfdump -R /var/cache/nfdump -o extended
```

This is **optional** — the iptables NETFLOW approach is lighter weight and works without
additional software.

## Customizing What to Capture

### Filter by Protocol

```bash
# Add iptables rule to count only TCP SYN
iptables -t raw -A NETFLOW -i darkspace-gre -p tcp --syn \
  -m comment --comment "netflow-tcp-syn" -j RETURN

# Count only ICMP
iptables -t raw -A NETFLOW -i darkspace-gre -p icmp \
  -m comment --comment "netflow-icmp" -j RETURN

# Count only UDP
iptables -t raw -A NETFLOW -i darkspace-gre -p udp \
  -m comment --comment "netflow-udp" -j RETURN
```

### Filter by Port

```bash
# Count SSH probes
iptables -t raw -A NETFLOW -i darkspace-gre -p tcp --dport 22 \
  -m comment --comment "netflow-ssh" -j RETURN

# Count HTTP probes
iptables -t raw -A NETFLOW -i darkspace-gre -p tcp --dport 80 \
  -m comment --comment "netflow-http" -j RETURN

# Count SMB probes
iptables -t raw -A NETFLOW -i darkspace-gre -p tcp --dport 445 \
  -m comment --comment "netflow-smb" -j RETURN
```

### Periodic Counter Snapshots

Create a cron job to log counter values:

```bash
# /etc/cron.d/darkspace-counters
*/5 * * * * root iptables -t raw -L NETFLOW -n -v --line-numbers | \
  awk '/netflow-/{print strftime("%Y-%m-%d %H:%M:%S"), $0}' >> /var/log/darkspace-counters.log
```

## Standalone Usage (Without Honeypot)

The `netflow` profile requires **only a router** — no traffic-host, no honeypot containers,
no cloud provider account. This makes it ideal for:

- **Network research**: Baseline darkspace traffic levels
- **Threat monitoring**: Detect scanning campaigns in real-time
- **Academic study**: Characterize internet background radiation
- **SOC integration**: Forward counters to SIEM via syslog
- **Testing**: Validate GRE tunnel before deploying honeypots

```bash
# Minimal deployment
sudo bash scripts/setup.sh   # Select profile 1 (netflow)
sudo bash scripts/deploy.sh  # Configures tunnel + monitoring

# That's it. Monitor traffic:
sudo tcpdump -i darkspace-gre -n
sudo iptables -t raw -L NETFLOW -n -v
```
