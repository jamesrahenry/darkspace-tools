# Traffic Analysis

Techniques for analyzing captured darkspace traffic and extracting actionable intelligence.

## Packet Capture

### Live Capture on GRE Interface

```bash
# All traffic (verbose)
sudo tcpdump -i darkspace-gre -nn -v

# TCP SYN only (connection attempts)
sudo tcpdump -i darkspace-gre -nn 'tcp[tcpflags] & tcp-syn != 0 and tcp[tcpflags] & tcp-ack == 0'

# Specific destination port
sudo tcpdump -i darkspace-gre -nn 'dst port 445'

# Traffic from a single source
sudo tcpdump -i darkspace-gre -nn 'src host 192.0.2.5'

# ICMP only
sudo tcpdump -i darkspace-gre -nn icmp
```

### Save to pcap

```bash
# Capture 10,000 packets
sudo tcpdump -i darkspace-gre -nn -w /tmp/darkspace-$(date +%Y%m%d-%H%M).pcap -c 10000

# Capture for a time period (60 seconds)
timeout 60 sudo tcpdump -i darkspace-gre -nn -w /tmp/darkspace-60s.pcap

# Rotating capture (100MB files, keep 10)
sudo tcpdump -i darkspace-gre -nn -w /tmp/darkspace-%Y%m%d-%H%M.pcap -C 100 -W 10
```

### Analyze pcap Files

```bash
# Read back
tcpdump -r /tmp/darkspace-*.pcap -nn

# Filter from pcap
tcpdump -r capture.pcap -nn 'tcp dst port 22'

# Use tshark for richer parsing
tshark -r capture.pcap -T fields -e ip.src -e ip.dst -e tcp.dstport | sort | uniq -c | sort -rn
```

## Statistical Analysis

### Top Source IPs

```bash
# From live traffic (30-second sample)
timeout 30 sudo tcpdump -i darkspace-gre -nn 2>/dev/null | \
  awk '{print $3}' | cut -d. -f1-4 | sort | uniq -c | sort -rn | head -20
```

### Top Destination Ports

```bash
timeout 30 sudo tcpdump -i darkspace-gre -nn 'tcp' 2>/dev/null | \
  awk '{print $5}' | rev | cut -d. -f1 | rev | sort | uniq -c | sort -rn | head -20
```

### Protocol Distribution

```bash
timeout 30 sudo tcpdump -i darkspace-gre -nn 2>/dev/null | \
  awk '{
    if (/TCP/) proto="TCP"
    else if (/UDP/) proto="UDP"
    else if (/ICMP/) proto="ICMP"
    else proto="OTHER"
    count[proto]++
  } END {
    for (p in count) printf "%8d %s\n", count[p], p
  }' | sort -rn
```

### Hourly Traffic Patterns

```bash
# From iptables counters (if cron logging is enabled)
awk '{print $1, $2}' /var/log/darkspace-counters.log | \
  cut -d: -f1 | uniq -c | \
  awk '{printf "%s %s: %d events\n", $2, $3, $1}'
```

## iptables Counter Analysis

### Current Counters

```bash
sudo iptables -t raw -L NETFLOW -n -v

# Parse into a summary
sudo iptables -t raw -L NETFLOW -n -v | awk '
  NR>2 && /netflow-/ {
    gsub(/\/\*|\*\//, "")
    name=$NF
    printf "%-30s  packets: %s  bytes: %s\n", name, $1, $2
  }'
```

### Counter Deltas (Change Over Time)

```bash
#!/bin/bash
# Save this as /usr/local/bin/netflow-delta.sh
TMPFILE="/tmp/netflow-prev"

# Get current
CURRENT=$(sudo iptables -t raw -L NETFLOW -n -v --line-numbers 2>/dev/null)

if [[ -f "$TMPFILE" ]]; then
    echo "=== Netflow Counter Deltas (since last check) ==="
    paste <(cat "$TMPFILE") <(echo "$CURRENT") | awk '
        NR>2 && /netflow-/ {
            prev_pkts=$1; prev_bytes=$2
            curr_pkts=$(NF/2+1); curr_bytes=$(NF/2+2)
            name=$NF
            printf "%-30s  +%s pkts  +%s bytes\n", name, curr_pkts-prev_pkts, curr_bytes-prev_bytes
        }'
fi

echo "$CURRENT" > "$TMPFILE"
```

## Honeypot Log Analysis

### Cowrie SSH/Telnet

```bash
# Top credential pairs
ssh root@<vpc-ip> 'docker logs cowrie 2>&1' | \
  grep "login attempt" | \
  grep -oP '\[.*?(username|password)=[^ \]]*' | \
  paste - - | sort | uniq -c | sort -rn | head -20

# Session duration analysis
ssh root@<vpc-ip> 'docker logs cowrie 2>&1' | \
  grep -E "connection lost|New connection" | head -40

# Most common commands executed
ssh root@<vpc-ip> 'docker logs cowrie 2>&1' | \
  grep "CMD:" | \
  sed 's/.*CMD: //' | sort | uniq -c | sort -rn | head -20

# Download attempts (malware staging)
ssh root@<vpc-ip> 'docker logs cowrie 2>&1' | \
  grep -iE "wget|curl|tftp|ftp|scp" | head -20
```

### Dionaea Multi-Protocol

```bash
# Connection timeline
ssh root@<vpc-ip> \
  'sqlite3 /opt/dionaea/var/dionaea/dionaea.sqlite \
   "SELECT datetime(connection_timestamp, \"unixepoch\"), remote_host, local_port, connection_type
    FROM connections ORDER BY connection_timestamp DESC LIMIT 30;"'

# Port scan detection (IPs hitting >5 ports)
ssh root@<vpc-ip> \
  'sqlite3 /opt/dionaea/var/dionaea/dionaea.sqlite \
   "SELECT remote_host, GROUP_CONCAT(DISTINCT local_port), COUNT(DISTINCT local_port) as ports
    FROM connections GROUP BY remote_host HAVING ports > 5 ORDER BY ports DESC LIMIT 20;"'

# Captured files (malware)
ssh root@<vpc-ip> 'ls -lh /opt/dionaea/var/dionaea/binaries/ 2>/dev/null'
ssh root@<vpc-ip> 'sha256sum /opt/dionaea/var/dionaea/binaries/* 2>/dev/null'
```

### Suricata IDS

```bash
# Alert severity distribution
ssh root@<vpc-ip> \
  'cat /var/log/suricata/eve.json | jq -r "select(.event_type==\"alert\") | .alert.severity" | \
   sort | uniq -c | sort -rn'

# Alert categories
ssh root@<vpc-ip> \
  'cat /var/log/suricata/eve.json | jq -r "select(.event_type==\"alert\") | .alert.category" | \
   sort | uniq -c | sort -rn | head -20'

# Unique signatures triggered
ssh root@<vpc-ip> \
  'cat /var/log/suricata/eve.json | jq -r "select(.event_type==\"alert\") | .alert.signature_id" | \
   sort -u | wc -l'
```

## IOC Extraction

### IP Addresses

```bash
# Unique source IPs from all honeypots
{
  ssh root@<vpc-ip> 'docker logs cowrie 2>&1' | grep -oP '\d+\.\d+\.\d+\.\d+' 
  ssh root@<vpc-ip> 'sqlite3 /opt/dionaea/var/dionaea/dionaea.sqlite "SELECT DISTINCT remote_host FROM connections;"' 
  ssh root@<vpc-ip> 'cat /var/log/suricata/eve.json | jq -r "select(.event_type==\"alert\") | .src_ip"'
} 2>/dev/null | sort -u | grep -v "^10\.\|^192\.168\.\|^172\.1[6-9]\.\|^172\.2[0-9]\.\|^172\.3[01]\." > iocs-ips.txt

echo "Unique attacking IPs: $(wc -l < iocs-ips.txt)"
```

### File Hashes

```bash
ssh root@<vpc-ip> 'find /opt/dionaea/var/dionaea/binaries -type f -exec sha256sum {} \;' > iocs-sha256.txt
```

### URLs and Domains

```bash
# From Cowrie command logs
ssh root@<vpc-ip> 'docker logs cowrie 2>&1' | \
  grep -oP 'https?://[^ "]+' | sort -u > iocs-urls.txt

# Extract domains
cat iocs-urls.txt | awk -F/ '{print $3}' | sort -u > iocs-domains.txt
```

## Threat Intelligence Lookups

### AbuseIPDB

```bash
# Requires free API key from https://www.abuseipdb.com/
API_KEY="YOUR_KEY"
while IFS= read -r ip; do
  score=$(curl -sG "https://api.abuseipdb.com/api/v2/check" \
    --data-urlencode "ipAddress=$ip" -H "Key: $API_KEY" -H "Accept: application/json" | \
    jq -r '.data.abuseConfidenceScore')
  echo "$ip,$score"
  sleep 1  # Rate limit
done < iocs-ips.txt > threat-scores.csv
```

### VirusTotal (File Hashes)

```bash
# Requires free API key from https://www.virustotal.com/
VT_KEY="YOUR_KEY"
while IFS= read -r line; do
  hash=$(echo "$line" | awk '{print $1}')
  result=$(curl -s "https://www.virustotal.com/api/v3/files/$hash" \
    -H "x-apikey: $VT_KEY" | jq -r '.data.attributes.last_analysis_stats.malicious // 0')
  echo "$hash,$result detections"
  sleep 15  # Rate limit (4/min free tier)
done < iocs-sha256.txt > vt-results.csv
```

## Generating Reports

### Daily Summary Script

```bash
#!/bin/bash
# /usr/local/bin/darkspace-daily-report.sh
DATE=$(date +%Y-%m-%d)
REPORT="/var/log/darkspace-report-${DATE}.txt"

echo "=== Darkspace Daily Report: $DATE ===" > "$REPORT"
echo "" >> "$REPORT"

echo "--- GRE Tunnel Stats ---" >> "$REPORT"
ip -s link show darkspace-gre >> "$REPORT" 2>&1

echo "" >> "$REPORT"
echo "--- Netflow Counters ---" >> "$REPORT"
iptables -t raw -L NETFLOW -n -v >> "$REPORT" 2>&1

echo "" >> "$REPORT"
echo "--- Top 10 Source IPs (last 24h, from Suricata) ---" >> "$REPORT"
ssh root@<vpc-ip> 'cat /var/log/suricata/eve.json | \
  jq -r "select(.event_type==\"alert\") | .src_ip" | \
  sort | uniq -c | sort -rn | head -10' >> "$REPORT" 2>&1

echo "" >> "$REPORT"
echo "--- Top 10 Suricata Signatures ---" >> "$REPORT"
ssh root@<vpc-ip> 'cat /var/log/suricata/eve.json | \
  jq -r "select(.event_type==\"alert\") | .alert.signature" | \
  sort | uniq -c | sort -rn | head -10' >> "$REPORT" 2>&1

echo "Report saved to $REPORT"
```
