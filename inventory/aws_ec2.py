"""
aws_ec2.py — boto3 dynamic inventory for Ansible / AWX Tower.

Queries live EC2 instances and groups them by tag value so AWX always
targets current infrastructure without a static hosts file.

"""

import argparse
import json
import os
import sys

try:
    import boto3
    from botocore.exceptions import BotoCoreError, ClientError
except ImportError:
    print(
        "ERROR: boto3 is not installed. Run: pip install boto3",
        file=sys.stderr,
    )
    sys.exit(1)


# Configuration

TAG_KEY = os.environ.get("FLEET_TAG_KEY", "env")
TAG_VALUES = os.environ.get("FLEET_TAG_VALUE", "staging").split(",")
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
ANSIBLE_USER = os.environ.get("ANSIBLE_USER", "ubuntu")


# Core inventory builder

def get_inventory() -> dict:
    """
    Returns a fully populated Ansible dynamic inventory dict.

    Structure:
        {
          "_meta": {"hostvars": {<ip>: {...}, ...}},
          "staging": {"hosts": [<ip>, ...]},
          "all": {"children": ["staging", ...]}
        }
    """
    inventory: dict = {
        "_meta": {"hostvars": {}},
        "all": {"children": []},
    }

    try:
        ec2 = boto3.client("ec2", region_name=AWS_REGION)
    except BotoCoreError as exc:
        print(f"WARNING: Could not initialise boto3 EC2 client: {exc}", file=sys.stderr)
        return inventory

    filters = [
        {"Name": "instance-state-name", "Values": ["running"]},
        {"Name": f"tag:{TAG_KEY}", "Values": TAG_VALUES},
    ]

    try:
        paginator = ec2.get_paginator("describe_instances")
        pages = paginator.paginate(Filters=filters)
    except (BotoCoreError, ClientError) as exc:
        print(f"WARNING: EC2 DescribeInstances failed: {exc}", file=sys.stderr)
        return inventory

    for page in pages:
        for reservation in page["Reservations"]:
            for instance in reservation["Instances"]:
                public_ip = instance.get("PublicIpAddress")
                private_ip = instance.get("PrivateIpAddress", "")

                # Prefer public IP for AWX reachability; fall back to private
                host_ip = public_ip or private_ip
                if not host_ip:
                    continue

                # Extract tags into a flat dict
                tags = {t["Key"]: t["Value"] for t in instance.get("Tags", [])}
                group_name = tags.get(TAG_KEY, "ungrouped")

                # Build group if it doesn't exist yet
                if group_name not in inventory:
                    inventory[group_name] = {"hosts": []}
                    inventory["all"]["children"].append(group_name)

                inventory[group_name]["hosts"].append(host_ip)

                # Per-host variables consumed by Ansible
                inventory["_meta"]["hostvars"][host_ip] = {
                    "ansible_host": host_ip,
                    "ansible_user": ANSIBLE_USER,
                    "instance_id": instance.get("InstanceId", ""),
                    "instance_type": instance.get("InstanceType", ""),
                    "availability_zone": instance.get("Placement", {}).get("AvailabilityZone", ""),
                    "private_ip": private_ip,
                    "tags": tags,
                    # AWX injects the SSH key via credential; no key path needed here
                }

    return inventory


def get_host_vars(host: str) -> dict:
    """Return hostvars for a single host (called by Ansible with --host)."""
    inv = get_inventory()
    return inv["_meta"]["hostvars"].get(host, {})


# CLI entry point

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="boto3 dynamic inventory for Ansible")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--list", action="store_true", help="List all hosts")
    group.add_argument("--host", metavar="HOSTNAME", help="Get vars for a single host")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.list:
        result = get_inventory()
    else:
        result = get_host_vars(args.host)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
