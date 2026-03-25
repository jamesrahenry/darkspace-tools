#!/usr/bin/env python3
"""
Dynamic inventory script for darkspace-tools.
Discovers traffic-host droplets from DigitalOcean via doctl.
Prefers private VPC IPs for Ansible connections.
"""

import json
import subprocess
import sys
import os


def get_droplets():
    """Get list of traffic-host droplets from DigitalOcean."""
    try:
        result = subprocess.run(
            ["doctl", "compute", "droplet", "list",
             "--format", "ID,Name,PublicIPv4,PrivateIPv4,Status",
             "--no-header"],
            capture_output=True, text=True, check=True, timeout=30
        )
        return result.stdout.strip().split('\n')
    except (subprocess.CalledProcessError, FileNotFoundError, subprocess.TimeoutExpired):
        return []


def build_inventory():
    """Build Ansible inventory from DigitalOcean droplets."""
    inventory = {
        "_meta": {"hostvars": {}},
        "all": {"children": ["routers", "traffic_hosts"]},
        "routers": {"hosts": ["localhost"]},
        "traffic_hosts": {"hosts": []}
    }

    # Configure localhost (router)
    target_ip = os.environ.get("TARGET_IP", "198.51.100.50")
    darkspace_ip = os.environ.get("DARKSPACE_IP", "203.0.113.10")

    inventory["_meta"]["hostvars"]["localhost"] = {
        "ansible_connection": "local",
        "target_ip": target_ip,
        "gre_remote_ip": darkspace_ip,
        "gre_local_ip": "192.168.240.1",
        "gre_interface": os.environ.get("GRE_INTERFACE", "darkspace-gre")
    }

    # Discover traffic-host droplets
    ssh_key = os.environ.get("SSH_KEY_PATH", os.path.expanduser("~/.ssh/id_ed25519"))

    for line in get_droplets():
        if not line.strip():
            continue
        parts = line.split()
        if len(parts) < 5:
            continue

        droplet_id, name, public_ip, private_ip, status = parts[:5]

        if "traffic-host" not in name:
            continue
        if status != "active":
            continue

        # Prefer private IP for Ansible connection (VPC)
        ansible_host = private_ip if private_ip else public_ip

        inventory["traffic_hosts"]["hosts"].append(name)
        inventory["_meta"]["hostvars"][name] = {
            "ansible_host": ansible_host,
            "ansible_user": "root",
            "ansible_ssh_private_key_file": ssh_key,
            "ansible_ssh_common_args": "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null",
            "target_ip": target_ip,
            "droplet_id": droplet_id,
            "public_ip": public_ip,
            "private_ip": private_ip
        }

    return inventory


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--list":
        print(json.dumps(build_inventory(), indent=2))
    elif len(sys.argv) > 1 and sys.argv[1] == "--host":
        print(json.dumps({}))
    else:
        print(json.dumps(build_inventory(), indent=2))
