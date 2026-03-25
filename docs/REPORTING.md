# Reporting and Analysis

How to extract intelligence from captured darkspace data at each profile level.

## Per-Profile Reporting Capabilities

| Profile | Data Sources | Analysis Tools |
|---------|-------------|----------------|
| netflow | iptables counters, ipset stats, pcap files | tcpdump, awk, cron logs |
| ids | Suricata eve.json, fast.log | jq, Suricata rule analysis |
| honeypot-lite | Container logs (Cowrie JSON, Dionaea SQLite) | Docker logs, jq, sqlite3 |
| honeypot-full | All above + Elasticsearch indices | Kibana dashboards, ES API |

---

## Netflow Profile Reporting

### iptables Counter Export

```bash
# Current counters
sudo iptables -t raw -L NETFLOW -n -v

# Export to CSV (for spreadsheet analysis)
sudo iptables -t raw -L NETFLOW -n -v --line-numbers | \
  awk 'NR>2 {print NR-2","$1","$2","$NF}' > /tmp/netflow-counters.csv

# Historical counters (if cron job is set up)
cat /var/log/darkspace-counters.log
```

### pcap Analysis

```bash
# Capture traffic
sudo tcpdump -i darkspace-gre -n -w /tmp/capture.pcap -c 10000

# Top source IPs
tcpdump -r /tmp/capture.pcap -n | awk '{print $3}' | cut -d. -f1-4 | sort | uniq -c | sort -rn | head -20

# Top destination ports
tcpdump -r /tmp/capture.pcap -n 'tcp' | awk '{print $5}' | rev | cut -d. -f1 | rev | sort | uniq -c | sort -rn | head -20

# Protocol distribution
tcpdump -r /tmp/capture.pcap -n | awk '{print $4}' | sort | uniq -c | sort -rn
```

---

## IDS Profile Reporting (Suricata)

### Suricata Alert Logs

```bash
# Fast log (one-line alerts)
ssh root@<traffic-host-vpc-ip> 'tail -100 /var/log/suricata/fast.log'

# JSON alerts (detailed)
ssh root@<traffic-host-vpc-ip> 'tail -10 /var/log/suricata/eve.json | python3 -m json.tool'
```

### Analyzing eve.json

```bash
# Top alert signatures
ssh root@<traffic-host-vpc-ip> \
  'cat /var/log/suricata/eve.json | jq -r "select(.event_type==\"alert\") | .alert.signature" | sort | uniq -c | sort -rn | head -20'

# Top source IPs triggering alerts
ssh root@<traffic-host-vpc-ip> \
  'cat /var/log/suricata/eve.json | jq -r "select(.event_type==\"alert\") | .src_ip" | sort | uniq -c | sort -rn | head -20'

# Alerts in last hour
ssh root@<traffic-host-vpc-ip> \
  'cat /var/log/suricata/eve.json | jq -r "select(.event_type==\"alert\") | select(.timestamp > \"$(date -d \"1 hour ago\" -Iseconds)\") | .alert.signature"'

# Export alerts to CSV
ssh root@<traffic-host-vpc-ip> \
  'cat /var/log/suricata/eve.json | jq -r "select(.event_type==\"alert\") | [.timestamp, .src_ip, .src_port, .dest_ip, .dest_port, .alert.signature, .alert.severity] | @csv"' > /tmp/suricata-alerts.csv
```

---

## Honeypot-Lite Reporting

### Cowrie (SSH/Telnet)

```bash
# Recent login attempts
ssh root@<traffic-host-vpc-ip> 'docker logs cowrie --tail 50 2>&1 | grep "login attempt"'

# Top usernames
ssh root@<traffic-host-vpc-ip> \
  'docker logs cowrie 2>&1 | grep "login attempt" | grep -oP "username=\K[^ ]*" | sort | uniq -c | sort -rn | head -20'

# Top passwords
ssh root@<traffic-host-vpc-ip> \
  'docker logs cowrie 2>&1 | grep "login attempt" | grep -oP "password=\K[^ ]*" | sort | uniq -c | sort -rn | head -20'

# Commands run by attackers (after successful login)
ssh root@<traffic-host-vpc-ip> 'docker logs cowrie 2>&1 | grep "CMD:"'

# Files downloaded by attackers
ssh root@<traffic-host-vpc-ip> 'docker logs cowrie 2>&1 | grep -i "download"'

# Export Cowrie JSON logs
ssh root@<traffic-host-vpc-ip> 'cat /cowrie/cowrie-git/var/log/cowrie/cowrie.json' > /tmp/cowrie-export.json
```

### Dionaea (Multi-Protocol)

```bash
# Recent connections
ssh root@<traffic-host-vpc-ip> 'docker logs dionaea --tail 50'

# Captured malware samples
ssh root@<traffic-host-vpc-ip> 'ls -la /opt/dionaea/var/dionaea/binaries/'

# Connection summary from SQLite
ssh root@<traffic-host-vpc-ip> \
  'sqlite3 /opt/dionaea/var/dionaea/dionaea.sqlite "SELECT remote_host, local_port, connection_type, COUNT(*) as cnt FROM connections GROUP BY remote_host, local_port ORDER BY cnt DESC LIMIT 20;"'

# Top attacking IPs
ssh root@<traffic-host-vpc-ip> \
  'sqlite3 /opt/dionaea/var/dionaea/dionaea.sqlite "SELECT remote_host, COUNT(*) as cnt FROM connections GROUP BY remote_host ORDER BY cnt DESC LIMIT 20;"'
```

---

## Honeypot-Full Reporting (Elasticsearch + Kibana)

### Accessing Kibana

```bash
# SSH tunnel (recommended for security)
ssh -L 5601:<traffic-host-vpc-ip>:5601 root@<router-ip>
# Open: http://localhost:5601
# Login: elastic / <password from vault>
```

### Elasticsearch API Queries

```bash
# Proxy through SSH
ssh -L 9200:<traffic-host-vpc-ip>:9200 root@<router-ip>

# Total documents
curl -k -u elastic:<password> 'https://localhost:9200/_cat/indices?v'

# Recent Cowrie events (last 1 hour)
curl -k -u elastic:<password> 'https://localhost:9200/cowrie-*/_search?size=10&sort=timestamp:desc' | python3 -m json.tool

# Top source IPs across all honeypots
curl -k -u elastic:<password> 'https://localhost:9200/_all/_search' -H 'Content-Type: application/json' -d '{
  "size": 0,
  "aggs": {
    "top_sources": {
      "terms": {
        "field": "src_ip.keyword",
        "size": 20
      }
    }
  }
}'

# Attack timeline (events per hour)
curl -k -u elastic:<password> 'https://localhost:9200/_all/_search' -H 'Content-Type: application/json' -d '{
  "size": 0,
  "aggs": {
    "hourly": {
      "date_histogram": {
        "field": "timestamp",
        "calendar_interval": "hour"
      }
    }
  }
}'
```

### Pre-Built Kibana Queries

Once in Kibana, try these in the Discover tab:

| Query | What it finds |
|-------|--------------|
| `event_type: "alert"` | All Suricata IDS alerts |
| `eventid: "cowrie.login.failed"` | Failed SSH login attempts |
| `eventid: "cowrie.command.input"` | Commands run by attackers |
| `type: "dionaea" AND connection_type: "accept"` | Accepted connections |
| `src_ip: "192.0.2.*"` | Traffic from a specific network |

---

## Data Export

### Export to JSON

```bash
# All Cowrie logs
ssh root@<vpc-ip> 'docker logs cowrie 2>&1' > cowrie-export.log

# Suricata alerts
ssh root@<vpc-ip> 'cat /var/log/suricata/eve.json' > suricata-export.json

# Elasticsearch bulk export
curl -k -u elastic:<password> 'https://localhost:9200/cowrie-*/_search?scroll=1m&size=1000' > es-export.json
```

### Export to CSV

```bash
# Cowrie login attempts → CSV
ssh root@<vpc-ip> 'docker logs cowrie 2>&1 | grep "login attempt"' | \
  awk -F'[][]' '{print $2}' | sort > cowrie-logins.csv

# Suricata alerts → CSV
cat suricata-export.json | jq -r 'select(.event_type=="alert") | [.timestamp,.src_ip,.dest_port,.alert.signature] | @csv' > alerts.csv
```

### SIEM Integration

Forward logs to your SIEM via syslog:

```bash
# On traffic-host, forward Suricata to syslog
# Add to /etc/rsyslog.d/suricata.conf:
module(load="imfile")
input(type="imfile" File="/var/log/suricata/eve.json" Tag="suricata" Facility="local0")
local0.* @@your-siem-server:514
```

---

## Attack Pattern Analysis

### Identifying Scanning Campaigns

```bash
# Find IPs scanning multiple ports
ssh root@<vpc-ip> \
  'sqlite3 /opt/dionaea/var/dionaea/dionaea.sqlite \
   "SELECT remote_host, COUNT(DISTINCT local_port) as ports FROM connections GROUP BY remote_host HAVING ports > 5 ORDER BY ports DESC LIMIT 20;"'
```

### IOC Extraction

```bash
# Extract unique attacking IPs
ssh root@<vpc-ip> 'docker logs cowrie 2>&1 | grep -oP "\d+\.\d+\.\d+\.\d+" | sort -u' > iocs-ips.txt

# Extract downloaded file hashes
ssh root@<vpc-ip> 'find /opt/dionaea/var/dionaea/binaries -type f -exec sha256sum {} \;' > iocs-hashes.txt

# Extract usernames/passwords for credential stuffing analysis
ssh root@<vpc-ip> 'docker logs cowrie 2>&1 | grep "login attempt" | \
  grep -oP "(username|password)=[^ ]*" | sort | uniq -c | sort -rn' > credentials.txt
```

### Threat Intelligence Correlation

Cross-reference captured IPs against threat intelligence feeds:

```bash
# Check IPs against AbuseIPDB (requires API key)
while read ip; do
  curl -s "https://api.abuseipdb.com/api/v2/check?ipAddress=$ip" \
    -H "Key: YOUR_API_KEY" -H "Accept: application/json" | \
    jq -r "[.data.ipAddress, .data.abuseConfidenceScore, .data.totalReports] | @csv"
done < iocs-ips.txt > threat-intel.csv
```
