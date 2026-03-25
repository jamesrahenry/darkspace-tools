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

For traditional NetFlow v5/v9 export using userspace tools, you can add softflowd.
This is the easiest option — no kernel compilation required.

```bash
# Install
apt install softflowd nfdump

# Export NetFlow v9 from GRE interface to a local collector
softflowd -i darkspace-gre -n localhost:9995 -v 9

# Start collector
nfcapd -l /var/cache/nfdump -p 9995 -D

# Query flows
nfdump -R /var/cache/nfdump -o extended

# Top talkers in the last hour
nfdump -R /var/cache/nfdump -s srcip -n 20 -o extended

# Export to a remote collector (e.g., your SIEM)
softflowd -i darkspace-gre -n your-siem.example.com:2055 -v 9
```

### softflowd as a systemd service

```bash
cat > /etc/systemd/system/softflowd-darkspace.service << 'EOF'
[Unit]
Description=softflowd NetFlow exporter for darkspace GRE
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
ExecStart=/usr/sbin/softflowd -i darkspace-gre -n localhost:9995 -v 9 -p /run/softflowd-darkspace.pid
PIDFile=/run/softflowd-darkspace.pid
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now softflowd-darkspace
```

softflowd works well but operates in userspace — it copies every packet from the kernel
for flow tracking. For high-volume darkspace links, the kernel module approach below
has significantly lower CPU overhead.

---

## Kernel NetFlow Export with ipt_NETFLOW

`ipt_NETFLOW` is a Linux kernel module that exports NetFlow v5, v9, or IPFIX directly
from the kernel's netfilter framework. Packets are accounted inside the kernel and only
the flow records are sent to your collector — **no packet copying to userspace**.

This is the recommended approach for:
- High-volume darkspace links (> 10,000 pps)
- Low-resource VMs where CPU matters
- Production deployments feeding a SIEM or flow collector
- Anyone who wants NetFlow/IPFIX without running softflowd

### How It Works

```
Packet arrives on darkspace-gre
         │
         ▼
    netfilter hooks
         │
         ▼
   ipt_NETFLOW module (kernel space)
    ├─ Tracks per-flow state (src/dst IP, ports, protocol, bytes, packets)
    ├─ Aggregates into flow records
    ├─ Exports completed flows via UDP to collector
    └─ Packet continues through normal iptables processing
         │
         ▼
   Your NETFLOW iptables chain (counting)
   and/or forwarding to traffic-host
```

### Prerequisites

```bash
# Install build dependencies
apt update
apt install -y build-essential linux-headers-$(uname -r) \
  pkg-config iptables-dev libmnl-dev git

# Verify kernel headers match running kernel
ls /lib/modules/$(uname -r)/build
# Should exist and contain Makefile
```

### Building the Module

```bash
# Clone the ipt_NETFLOW repository
cd /usr/src
git clone https://github.com/aabc/ipt-netflow.git
cd ipt-netflow

# Configure (auto-detects kernel version and iptables paths)
./configure

# Build
make

# Install
make install

# Load the module
modprobe ipt_NETFLOW destination=127.0.0.1:2055 protocol=9
```

### Module Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `destination` | none (required) | Collector address as `host:port` |
| `protocol` | `5` | Export protocol: `5` (NetFlow v5), `9` (NetFlow v9), `10` (IPFIX) |
| `active_timeout` | `1800` | Seconds before active flows are exported (30 min) |
| `inactive_timeout` | `15` | Seconds of inactivity before a flow is exported |
| `hashsize` | auto | Flow hash table size (auto-tuned to RAM) |
| `maxflows` | `2000000` | Maximum concurrent tracked flows |
| `sndbuf` | `0` (auto) | UDP send buffer size in bytes |
| `aggregation` | none | Aggregate flows (e.g., strip ports: `port=0` ) |

### Configuring with iptables

The module works as an iptables target. Any packet matching a `-j NETFLOW` rule is
tracked for flow export. Packets are **not dropped** — they continue through the chain.

```bash
# Export ALL traffic on the GRE interface
iptables -I INPUT -i darkspace-gre -j NETFLOW
iptables -I FORWARD -i darkspace-gre -j NETFLOW

# Or: export only specific traffic
iptables -I INPUT -i darkspace-gre -p tcp -j NETFLOW
iptables -I INPUT -i darkspace-gre -p udp -j NETFLOW
iptables -I INPUT -i darkspace-gre -p icmp -j NETFLOW
```

> **Important**: The `NETFLOW` target in ipt_NETFLOW is different from the custom
> `NETFLOW` chain we create for iptables counting. They can coexist — the kernel module
> target exports flows to your collector, while the custom chain provides local counters.
> If you use both, add the `-j NETFLOW` (target) rules before the `-j NETFLOW` (chain) jump.

### Runtime Configuration via /proc

Once loaded, the module exposes runtime controls:

```bash
# View current status
cat /proc/net/stat/ipt_netflow

# Example output:
#   ipt_NETFLOW version 3.2 (2024-01-15)
#   Flows: active 1247, allocated 2048, memory 163840
#   Packets: received 4823910, exported in 23841 flows
#   Destinations: 127.0.0.1:2055 (protocol 9), errors 0
#   Hash: size 65536, memory 524288

# Change export destination at runtime
echo "destination=192.0.2.100:9995" > /proc/net/stat/ipt_netflow

# Change protocol at runtime
echo "protocol=10" > /proc/net/stat/ipt_netflow  # Switch to IPFIX

# Change timeout
echo "inactive_timeout=30" > /proc/net/stat/ipt_netflow

# Flush all active flows immediately
echo "flush=1" > /proc/net/stat/ipt_netflow
```

### Persistent Module Loading

```bash
# Add to /etc/modules-load.d/
echo "ipt_NETFLOW" > /etc/modules-load.d/ipt-netflow.conf

# Module options in /etc/modprobe.d/
cat > /etc/modprobe.d/ipt-netflow.conf << 'EOF'
options ipt_NETFLOW destination=127.0.0.1:2055 protocol=9 \
  active_timeout=300 inactive_timeout=15 hashsize=65536
EOF

# Persistent iptables rules (add NETFLOW target rules)
iptables -I INPUT -i darkspace-gre -j NETFLOW
iptables -I FORWARD -i darkspace-gre -j NETFLOW
iptables-save > /etc/iptables/rules.v4
```

### Sending to Multiple Collectors

```bash
# Module supports multiple destinations (comma-separated)
modprobe ipt_NETFLOW destination=192.0.2.100:2055,192.0.2.200:9996 protocol=9

# Or add at runtime
echo "destination=192.0.2.100:2055,192.0.2.200:9996" > /proc/net/stat/ipt_netflow
```

### Automatic Rebuild on Kernel Updates (DKMS)

To survive kernel upgrades, register the module with DKMS:

```bash
# Install DKMS
apt install dkms

# Register (from the ipt-netflow source directory)
cd /usr/src/ipt-netflow
make dkms-install

# Verify
dkms status
# Expected: ipt-netflow, <version>, <kernel>, x86_64: installed

# Now kernel updates will auto-rebuild the module
```

### Verifying It Works

```bash
# 1. Check module is loaded
lsmod | grep ipt_NETFLOW

# 2. Check iptables rules with NETFLOW target
iptables -L INPUT -n -v | grep NETFLOW

# 3. Watch flow export stats
watch -n1 cat /proc/net/stat/ipt_netflow

# 4. Verify flows arrive at collector (if using nfcapd locally)
nfdump -R /var/cache/nfdump -o extended -c 10

# 5. Capture NetFlow UDP packets to verify export
tcpdump -i lo -n port 2055 -c 10
```

### Collector Options

The kernel module exports standard NetFlow/IPFIX — any collector will work:

| Collector | Type | Install |
|-----------|------|---------|
| **nfcapd** (nfdump) | CLI, stores to disk | `apt install nfdump` |
| **ntopng** | Web UI, real-time | `apt install ntopng` |
| **Elastic (Filebeat)** | Filebeat NetFlow input | Elastic Stack |
| **GoFlow2** | Lightweight, JSON output | Go binary |
| **pmacct** | Flexible, SQL backend | `apt install pmacct` |
| **Logstash** | NetFlow codec plugin | Elastic Stack |
| **PRTG / SolarWinds** | Commercial NMS | Commercial |

#### Example: nfcapd local collector

```bash
# Install
apt install nfdump

# Create data directory
mkdir -p /var/cache/nfdump

# Start collector (listens on UDP 2055, rotates files every 5 min)
nfcapd -l /var/cache/nfdump -p 2055 -t 300 -D

# Query recent flows
nfdump -R /var/cache/nfdump -o extended

# Top source IPs
nfdump -R /var/cache/nfdump -s srcip -n 20

# Top destination ports
nfdump -R /var/cache/nfdump -s dstport -n 20

# Flows in the last hour targeting SSH
nfdump -R /var/cache/nfdump -t 2024/01/15.10:00:00-2024/01/15.11:00:00 'dst port 22'
```

#### Example: Export to remote Elastic Stack

```bash
# Load module pointing to your Logstash host
modprobe ipt_NETFLOW destination=elastic.example.com:2055 protocol=9

# In Logstash, use the netflow codec:
# input {
#   udp {
#     port => 2055
#     codec => netflow { versions => [5, 9] }
#   }
# }
# output {
#   elasticsearch {
#     hosts => ["http://localhost:9200"]
#     index => "darkspace-netflow-%{+YYYY.MM.dd}"
#   }
# }
```

### ipt_NETFLOW vs softflowd vs iptables Counters

| Feature | ipt_NETFLOW (kernel) | softflowd (userspace) | iptables counters |
|---------|---------------------|----------------------|-------------------|
| **CPU overhead** | Minimal (kernel-space) | Moderate (copies packets) | Minimal |
| **Flow records** | Yes — full 5-tuple flows | Yes — full 5-tuple flows | No — aggregate counters only |
| **Export protocols** | NetFlow v5/v9, IPFIX | NetFlow v5/v9 | None (read via iptables -L) |
| **Multi-collector** | Yes (native) | One destination | N/A |
| **Requires compilation** | Yes (DKMS auto-rebuilds) | No (apt install) | No |
| **Best for** | Production, high volume | Quick setup, low volume | Simple counting, no collector |

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
- **SOC integration**: Forward NetFlow/IPFIX to your SIEM or flow collector
- **Testing**: Validate GRE tunnel before deploying honeypots

### Quick Start (Counters Only)

```bash
# Minimal deployment
sudo bash scripts/setup.sh   # Select profile 1 (netflow)
sudo bash scripts/deploy.sh  # Configures tunnel + monitoring

# That's it. Monitor traffic:
sudo tcpdump -i darkspace-gre -n
sudo iptables -t raw -L NETFLOW -n -v
```

### Quick Start (NetFlow Export to Collector)

```bash
# 1. Deploy netflow profile
sudo bash scripts/setup.sh   # Select profile 1 (netflow)
sudo bash scripts/deploy.sh

# 2. Install and load kernel NetFlow module
apt install -y build-essential linux-headers-$(uname -r) iptables-dev git
cd /usr/src && git clone https://github.com/aabc/ipt-netflow.git && cd ipt-netflow
./configure && make && make install && make dkms-install
modprobe ipt_NETFLOW destination=<your-collector>:2055 protocol=9

# 3. Add iptables rules
iptables -I INPUT -i darkspace-gre -j NETFLOW
iptables -I FORWARD -i darkspace-gre -j NETFLOW
iptables-save > /etc/iptables/rules.v4

# 4. Verify
cat /proc/net/stat/ipt_netflow
```

### Quick Start (softflowd — No Compilation)

```bash
# 1. Deploy netflow profile
sudo bash scripts/setup.sh   # Select profile 1 (netflow)
sudo bash scripts/deploy.sh

# 2. Install and start softflowd
apt install softflowd nfdump
softflowd -i darkspace-gre -n <your-collector>:2055 -v 9

# 3. Or collect locally
nfcapd -l /var/cache/nfdump -p 2055 -D
nfdump -R /var/cache/nfdump -o extended
```
