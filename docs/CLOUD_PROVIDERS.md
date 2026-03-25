# Cloud Provider Adaptation

darkspace-tools is built for DigitalOcean but can be adapted to other cloud providers
or on-premises infrastructure. This guide covers what needs to change.

## Architecture Requirements

Any deployment needs:

1. **Router node** — public IP, receives GRE tunnel, runs NAT/forwarding
2. **Traffic-host node** (optional, for ids/honeypot profiles) — private network, runs services
3. **Private network** between router and traffic-host
4. **GRE tunnel endpoint** — the darkspace source that sends traffic

## DigitalOcean (Primary)

The default configuration. No adaptation needed.

```bash
# Prerequisites
doctl auth init
doctl compute ssh-key list

# Deploy
bash scripts/setup.sh
bash scripts/deploy.sh
```

**Key features used:**
- Droplets (VMs)
- VPC (private networking)
- doctl CLI for automation
- Metadata API (169.254.169.254)

## AWS

### Mapping

| DigitalOcean | AWS Equivalent |
|-------------|---------------|
| Droplet | EC2 Instance |
| VPC | VPC |
| Private networking | VPC Subnets |
| doctl | aws cli |
| Floating IP | Elastic IP |

### Changes Required

**1. Infrastructure provisioning** — Replace `doctl` commands in `scripts/deploy.sh`:

```bash
# Instead of:
doctl compute droplet create ...

# Use:
aws ec2 run-instances \
  --image-id ami-0c55b159cbfafe1f0 \
  --instance-type t3.small \
  --subnet-id subnet-xxx \
  --security-group-ids sg-xxx \
  --key-name darkspace-key
```

**2. Security groups** — AWS uses security groups instead of host-level UFW. Create:

```bash
# Router security group
aws ec2 create-security-group --group-name darkspace-router --vpc-id vpc-xxx
aws ec2 authorize-security-group-ingress --group-id sg-xxx --protocol tcp --port 22 --cidr YOUR_IP/32
aws ec2 authorize-security-group-ingress --group-id sg-xxx --protocol 47 --cidr DARKSPACE_SOURCE/32  # GRE

# Traffic-host security group (VPC only)
aws ec2 create-security-group --group-name darkspace-traffic --vpc-id vpc-xxx
aws ec2 authorize-security-group-ingress --group-id sg-xxx --protocol -1 --source-group sg-router-xxx
```

**3. VPC setup:**

```bash
aws ec2 create-vpc --cidr-block 10.100.0.0/16
aws ec2 create-subnet --vpc-id vpc-xxx --cidr-block 10.100.1.0/24
```

**4. Inventory** — Update `ansible/dynamic-inventory.py` to use `boto3`:

```python
import boto3
ec2 = boto3.client('ec2')
instances = ec2.describe_instances(Filters=[{'Name': 'tag:Project', 'Values': ['darkspace']}])
```

**5. Important:** Disable AWS source/destination check on the router instance (required for NAT):

```bash
aws ec2 modify-instance-attribute --instance-id i-xxx --no-source-dest-check
```

## GCP

### Mapping

| DigitalOcean | GCP Equivalent |
|-------------|---------------|
| Droplet | Compute Engine VM |
| VPC | VPC Network |
| Private networking | Subnets |
| doctl | gcloud cli |

### Changes Required

**1. Create VMs:**

```bash
# Router
gcloud compute instances create darkspace-router \
  --machine-type=e2-small \
  --network=darkspace-vpc \
  --subnet=darkspace-subnet \
  --zone=us-central1-a

# Traffic-host (no external IP)
gcloud compute instances create darkspace-traffic \
  --machine-type=e2-medium \
  --network=darkspace-vpc \
  --subnet=darkspace-subnet \
  --no-address \
  --zone=us-central1-a
```

**2. Firewall rules:**

```bash
# Allow GRE
gcloud compute firewall-rules create allow-gre \
  --network=darkspace-vpc \
  --allow=47 \
  --source-ranges=DARKSPACE_SOURCE/32

# Allow internal
gcloud compute firewall-rules create allow-internal \
  --network=darkspace-vpc \
  --allow=all \
  --source-ranges=10.100.0.0/16
```

**3. Enable IP forwarding** on router VM:

```bash
gcloud compute instances create darkspace-router ... --can-ip-forward
```

## Hetzner

### Mapping

| DigitalOcean | Hetzner Equivalent |
|-------------|-------------------|
| Droplet | Cloud Server |
| VPC | Network |
| doctl | hcloud cli |

### Changes Required

```bash
# Create network
hcloud network create --name darkspace-net --ip-range 10.100.0.0/16
hcloud network add-subnet darkspace-net --network-zone eu-central --type cloud --ip-range 10.100.0.0/24

# Create servers
hcloud server create --name darkspace-router --type cx21 --image debian-12 --network darkspace-net
hcloud server create --name darkspace-traffic --type cx21 --image debian-12 --network darkspace-net
```

Hetzner servers get public IPs by default. Remove the public IP from traffic-host or use their firewall to block external access.

## On-Premises / Bare Metal

### Requirements

- Two Linux machines (Debian 12+ or Ubuntu 22.04+)
- Private network between them (VLAN, direct link, or VPN)
- Public IP on the router machine
- GRE source configured to send to router's public IP

### Setup

1. **Skip cloud provisioning** — comment out or skip the `doctl` parts of `scripts/deploy.sh`
2. **Create inventory manually:**

```yaml
# ansible/inventory.yml
all:
  children:
    routers:
      hosts:
        router-01:
          ansible_host: <router-ip>
          public_ip: <router-public-ip>
          vpc_ip: <router-private-ip>
    traffic_hosts:
      hosts:
        traffic-01:
          ansible_host: <traffic-host-private-ip>
          vpc_ip: <traffic-host-private-ip>
          ansible_ssh_common_args: '-o ProxyJump=root@<router-ip>'
```

3. **Run Ansible directly:**

```bash
ansible-playbook -i ansible/inventory.yml ansible/deploy-all.yml \
  -e "profile=honeypot-full" \
  -e "target_ip=<your-target-ip>" \
  -e "darkspace_host=<gre-source-ip>" \
  --ask-vault-pass
```

4. **Network config** — ensure private network routing works:

```bash
# On traffic-host, add router as default gateway for target IP
ip route add default via <router-private-ip> table target_replies
```

## Common Adaptation Tasks

### Replace doctl Commands

Search for `doctl` in scripts and replace with your provider's CLI:

```bash
grep -rn "doctl" scripts/
```

### Update Inventory Discovery

The `dynamic-inventory.py` script uses DigitalOcean's API. For other providers, either:

- **Option A:** Write a new dynamic inventory for your provider
- **Option B:** Use a static inventory file (simpler)

### Adjust Network Interface Names

DigitalOcean uses `eth0` (public) and `eth1` (VPC). Other providers may differ:

| Provider | Public | Private |
|----------|--------|---------|
| DigitalOcean | eth0 | eth1 |
| AWS | eth0 | eth0 (same interface, VPC-only) |
| GCP | ens4 | ens4 (same, VPC) |
| Hetzner | eth0 | ens10 |
| Bare metal | varies | varies |

Update interface names in:
- `ansible/deploy-router.yml`
- `ansible/deploy-traffic-host.yml`
- `scripts/deploy.sh`
