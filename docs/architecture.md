# Architecture: Fleet Config & Patch Automation

## System Overview

```
┌─────────────────────────────────────────────────────────────────┐
│  GitHub                                                          │
│  fleet-config repo                                               │
│  ├── playbooks/          ← 4 playbooks                           │
│  ├── roles/              ← business logic                        │
│  ├── inventory/aws_ec2.py ← boto3 dynamic inventory             │
│  └── .github/workflows/lint.yml ← CI gate                       │
└──────────────────────────────┬──────────────────────────────────┘
                               │ SCM pull (on launch)
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│  EC2 t3.micro — AWX Control Node (Ubuntu 22.04)                  │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌────────────────┐   │
│  │ postgres │  │  redis   │  │ awx_web  │  │   awx_task     │   │
│  │   :5432  │  │  :6379   │  │  :8052   │  │  (job runner)  │   │
│  └──────────┘  └──────────┘  └──────────┘  └───────┬────────┘   │
│                                                     │            │
│  IAM Instance Profile (read-only EC2 perms)         │            │
│  ↳ ec2:DescribeInstances                            │            │
│  ↳ ec2:DescribeTags                                 │            │
└─────────────────────────────────────────────────────┼───────────┘
                                                      │
                               ┌──────────────────────┘
                               │ ansible-playbook over SSH
                               │ (uses fleet_key.pem Machine Credential)
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│  Fleet Targets — EC2 t2.micro × N (Ubuntu 22.04)                 │
│  Tagged: env=staging                                             │
│                                                                  │
│  ┌─────────────┐  ┌─────────────┐                               │
│  │  target-01  │  │  target-02  │  ...                          │
│  │ 10.0.1.15   │  │ 10.0.1.16   │                               │
│  └─────────────┘  └─────────────┘                               │
└─────────────────────────────────────────────────────────────────┘
```

## Dynamic Inventory Flow

```
AWX launches job
     │
     ▼
inventory/aws_ec2.py --list
     │
     ├── boto3.client('ec2').get_paginator('describe_instances')
     │   Filters: running + tag:env=staging
     │
     ▼
JSON: { "staging": { "hosts": ["10.0.1.15", ...] }, "_meta": { "hostvars": {...} } }
     │
     ▼
AWX builds host list → Ansible connects via SSH
```

## AWX Job Templates

| Template | Playbook | Schedule | Extra Vars |
|----------|----------|----------|------------|
| Patch Management | patch_management.yml | Nightly 02:00 UTC | cve_id, skip_reboot |
| Config Drift Detect | config_drift.yml | Weekly Sun 03:00 | drift_fix=false |
| Config Drift Fix | config_drift.yml | Manual only | drift_fix=true |
| Security Hardening | security_hardening.yml | Weekly Sun 04:00 | — |
| User Provisioning | user_provisioning.yml | Manual (on roster change) | — |

## IAM Trust Boundary

```
AWX EC2 Instance
└── IAM Instance Profile
    └── Role: fleet-awx-inventory-role
        └── Policy: fleet-ec2-read-only
            ├── ec2:DescribeInstances   (no write access)
            └── ec2:DescribeTags

Target EC2 Instances
└── No IAM permissions needed
    └── Auth is SSH key only (fleet_key.pem stored in AWX Machine Credential)
```

No AWS credentials are stored in code or environment variables.  
The boto3 inventory script picks up the instance profile automatically via the EC2 metadata endpoint.

## AWX RBAC Model

| Team | Role | Can Do |
|------|------|--------|
| platform-sre | Admin | Create/edit templates, schedules, credentials |
| on-call-sre | Execute | Launch job templates, view job output |
| read-only | Read | View job history, inventory |

## Idempotency Guarantee

Every playbook is run twice in `tests/idempotency_runner.sh`.  
Second run must report `changed=0, failed=0` — committed logs in `tests/idempotency_results/` serve as the audit trail.

## Credential Flow

```
AWX Credential Store (encrypted at rest)
├── Machine Credential: fleet-ssh-key
│   └── fleet_key.pem (EC2 SSH private key)
└── Cloud Credential: AWS (optional — if not using instance profile)
    └── Not used in this design (instance profile preferred)
```
