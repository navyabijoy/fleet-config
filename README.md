# fleet-config

![Lint Status](https://github.com/<YOUR_ORG>/fleet-config/actions/workflows/lint.yml/badge.svg)

Fleet configuration management and patch automation using Ansible and AWX Tower.  
Runs entirely on AWS free tier.

## What's in here

| Playbook | What it does |
|----------|-------------|
| `patch_management.yml` | OS updates with business-hours reboot gate |
| `config_drift.yml` | Detects (and optionally fixes) sshd/sudoers deviations from baseline |
| `security_hardening.yml` | CIS-mapped SSH hardening, fail2ban, UFW port restriction |
| `user_provisioning.yml` | Idempotent SSH key + sudo access for the fleet |

**Dynamic inventory**: `inventory/aws_ec2.py` — boto3 pulls live EC2 instances by tag (`env:staging`).  
**Orchestration**: AWX Tower (Docker Compose on EC2 t3.micro) — scheduled runs + ad-hoc emergency patch with survey.

## Project Structure

```
fleet-config/
├── inventory/aws_ec2.py        # boto3 dynamic inventory
├── playbooks/                  # 4 playbooks
├── roles/                      # Role logic (tasks, handlers, defaults)
├── vars/                       # baseline_config.yml, users.yml
├── awx/                        # AWX Docker Compose + config-as-code
├── tests/                      # idempotency_runner.sh + committed logs
├── docs/                       # SOP, architecture diagram
└── .github/workflows/lint.yml  # CI: yamllint + ansible-lint
```

## Prerequisites

```bash
pip install ansible ansible-lint yamllint boto3 awxkit
ansible-galaxy collection install -r requirements.yml
```

## Quick Start

### 1. Set up AWS

Tag 1–2 EC2 t2.micro instances (Ubuntu 22.04): `env=staging`

### 2. Test dynamic inventory

```bash
export AWS_DEFAULT_REGION=us-east-1
chmod +x inventory/aws_ec2.py
python3 inventory/aws_ec2.py --list
```

### 3. Run a playbook (local)

```bash
export ANSIBLE_PRIVATE_KEY_FILE=~/.ssh/fleet_key.pem
ansible-playbook playbooks/security_hardening.yml -i inventory/aws_ec2.py --diff
```

### 4. Bootstrap AWX

See [awx/README_setup.md](awx/README_setup.md) for the full AWX setup guide on EC2 t3.micro.

### 5. Prove idempotency

```bash
chmod +x tests/idempotency_runner.sh
./tests/idempotency_runner.sh
# Expected: "Results: 4 passed, 0 failed"
```

## AWX Schedules

| Schedule | Playbook | Cron |
|----------|----------|------|
| Nightly Patch Check | patch_management.yml | `0 2 * * *` UTC |
| Weekly Drift Scan | config_drift.yml | `0 3 * * 0` UTC |
| Weekly Hardening Audit | security_hardening.yml | `0 4 * * 0` UTC |

## Emergency Patch (AWX Survey)

Launch the **Patch Management** template with the survey to supply:
- `cve_id` — CVE reference for audit logging
- `target_env` — staging or prod
- `skip_reboot` — override the business-hours reboot gate

## Documentation

- [Architecture](docs/architecture.md) — system diagram, IAM trust boundary, AWX RBAC
- [SOP: Onboard a Playbook](docs/SOP_onboard_playbook.md) — step-by-step for new playbooks

## Cost

Runs entirely on AWS free tier. Stop instances when not demoing:
`aws ec2 stop-instances --instance-ids <id1> <id2> <id3>`
