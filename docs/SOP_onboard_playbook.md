# SOP: Onboarding a New Playbook into AWX Tower

**Audience**: Junior SRE joining the Fleet Config team  
**Last updated**: 2024-01  
**Owner**: Platform SRE

---

## Overview

This SOP covers the end-to-end process of adding a new Ansible playbook to the fleet-config repository and wiring it into AWX Tower — from writing the role to verifying idempotency and setting a schedule.

---

## Prerequisites

- Write access to this repository
- Python 3.11+, `ansible`, `ansible-lint`, `yamllint` installed locally
- `awxkit` installed: `pip install awxkit`
- `AWX_HOST`, `AWX_USERNAME`, `AWX_PASSWORD` exported in your shell

---

## Step 1: Write the Role

Create the role directory structure:

```bash
mkdir -p roles/<role_name>/{tasks,handlers,defaults}
touch roles/<role_name>/tasks/main.yml
touch roles/<role_name>/handlers/main.yml
touch roles/<role_name>/defaults/main.yml
```

**Rules for all roles in this project:**

1. **Every task must have a `name`** — ansible-lint will fail without it.
2. **State changes via handlers only** — no bare `service` restarts inline; use `notify: <Handler Name>`.
3. **All service-touching tasks must be idempotent** — test with `--check` before applying.
4. **Document CIS/compliance references** in task names where applicable (e.g. `CIS 5.2.4 | Disable root SSH`).
5. **Tag tasks** with at least the role name (e.g. `tags: [hardening]`) for selective runs.

---

## Step 2: Create the Playbook

```yaml
# playbooks/<playbook_name>.yml
---
- name: <Human-readable description>
  hosts: staging
  gather_facts: true
  become: true

  vars_files:
    - ../vars/<any_required_vars>.yml

  roles:
    - role: <role_name>
```

Register any Galaxy dependencies in `requirements.yml`:

```yaml
collections:
  - name: community.general
    version: ">=8.0.0"
```

---

## Step 3: Run the Lint Gate Locally

Before pushing, run all linters locally to catch issues before CI:

```bash
yamllint .
ansible-lint playbooks/<playbook_name>.yml
ansible-playbook --syntax-check playbooks/<playbook_name>.yml -i tests/stub_inventory
```

Fix all errors. Warnings from `warn_list` are advisory; errors block the PR.

---

## Step 4: Open a Pull Request

Push your branch. GitHub Actions runs `.github/workflows/lint.yml` automatically:

- `yamllint .`
- `ansible-lint playbooks/`
- `ansible-playbook --syntax-check` for every playbook

**The PR cannot merge until all checks pass.**

---

## Step 5: Prove Idempotency Against Real EC2

After PR is approved but before merge:

```bash
# Ensure you're targeting the staging fleet
export FLEET_TAG_KEY=env
export FLEET_TAG_VALUE=staging
export ANSIBLE_PRIVATE_KEY_FILE=~/.ssh/fleet_key.pem

# Run just the new playbook twice
ansible-playbook playbooks/<playbook_name>.yml -i inventory/aws_ec2.py --diff -v > /tmp/run1.log 2>&1
ansible-playbook playbooks/<playbook_name>.yml -i inventory/aws_ec2.py --diff -v > /tmp/run2.log 2>&1

# Check second run
grep "changed=" /tmp/run2.log
# Expected: changed=0, failed=0
```

Commit the run2 log to `tests/idempotency_results/<playbook>_run2_<timestamp>.log`.

---

## Step 6: Create the AWX Job Template

After merge to `main`, sync AWX project and create the job template:

```bash
export AWX_HOST=http://<AWX_EC2_IP>
export AWX_USERNAME=admin
export AWX_PASSWORD=<password>

# Add the new template to awx/job_templates.sh and run:
bash awx/job_templates.sh
```

Or manually in AWX UI:
1. **Templates → Add → Job Template**
2. Set inventory to `fleet-staging`
3. Set project to `fleet-config`
4. Set playbook to `playbooks/<playbook_name>.yml`
5. Enable **Ask variables on launch** if the playbook accepts extra vars
6. Save

---

## Step 7: Set a Schedule (if recurring)

In AWX UI: Open the template → **Schedules → Add**

| Field | Example |
|-------|---------|
| Name | Weekly Playbook Name |
| Start date/time | Next Sunday 03:00 UTC |
| Repeat frequency | Weekly |
| Day of week | Sunday |

Or add to `awx/job_templates.sh` using the `awx schedules create` command pattern already in the script.

---

## Step 8: Verify in AWX

1. Click **Launch** on the new template → verify green status
2. Open the job output and confirm `changed=0` on a second manual launch
3. Confirm the schedule appears in **Schedules** tab with the correct next run time

---

## Checklist Summary

```
[ ] Role created with tasks, handlers, defaults
[ ] All tasks named and tagged
[ ] State changes use handlers, not inline restarts
[ ] yamllint passing
[ ] ansible-lint passing
[ ] Syntax check passing
[ ] PR opened, CI green
[ ] Idempotency proven: run2 log committed
[ ] AWX job template created via job_templates.sh
[ ] Schedule set (if recurring)
[ ] Manual AWX launch verified green
[ ] Second AWX launch shows changed=0
```
