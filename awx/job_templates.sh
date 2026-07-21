#!/usr/bin/env bash
# Creates/updates all job templates, schedules, and the emergency patch survey.
# Requires awxkit and AWX_* env vars.

set -euo pipefail

# Validate environment variables
: "${AWX_HOST:?Set AWX_HOST env var (e.g. http://1.2.3.4)}"
: "${AWX_USERNAME:?Set AWX_USERNAME env var}"
: "${AWX_PASSWORD:?Set AWX_PASSWORD env var}"

readonly AWX_ARGS="--conf.host ${AWX_HOST} --conf.username ${AWX_USERNAME} --conf.password ${AWX_PASSWORD} --conf.insecure"

# Helpers

log()  { echo "==> $*"; }
step() { echo "--> $*"; }

# Run an AWX CLI command, treating "already exists" as a no-op.
awx_idempotent() {
  awx ${AWX_ARGS} "$@" 2>/dev/null || true
}

# Fetch a single numeric ID for a named resource.
# Usage: get_id <resource> <name>
get_id() {
  local resource="$1" name="$2"
  awx ${AWX_ARGS} "${resource}" list --name "${name}" -f json \
    | python3 -c "import sys,json; d=json.load(sys.stdin); \
        results=d.get('results',[]); \
        print(results[0]['id'] if results else '') "
}

# 1. Organisation
log "Configuring AWX at ${AWX_HOST}"
step "Ensuring organisation: Fleet Ops"
awx_idempotent organizations create \
  --name "Fleet Ops" \
  --description "Fleet Config Automation"

ORG_ID=$(get_id organizations "Fleet Ops")
if [[ -z "${ORG_ID}" ]]; then
  echo "ERROR: Could not resolve organisation ID for 'Fleet Ops'" >&2
  exit 1
fi

# 2. Inventory
step "Creating inventory: fleet-staging"
awx_idempotent inventory create \
  --name "fleet-staging" \
  --organization "${ORG_ID}" \
  --description "Dynamic EC2 inventory via boto3 (env:staging)"

INV_ID=$(get_id inventory "fleet-staging")
if [[ -z "${INV_ID}" ]]; then
  echo "ERROR: Could not resolve inventory ID for 'fleet-staging'" >&2
  exit 1
fi

# 3. Project
step "Creating project: fleet-config"
awx_idempotent projects create \
  --name "fleet-config" \
  --organization "${ORG_ID}" \
  --scm_type "git" \
  --scm_url "https://github.com/<YOUR_ORG>/fleet-config.git" \
  --scm_branch "main" \
  --scm_clean true \
  --scm_update_on_launch true \
  --description "Fleet Config & Patch Automation"

PROJ_ID=$(get_id projects "fleet-config")
if [[ -z "${PROJ_ID}" ]]; then
  echo "ERROR: Could not resolve project ID for 'fleet-config'" >&2
  exit 1
fi

# 4. Job templates

create_template() {
  local name="$1" playbook="$2" extra_vars="$3"
  step "Ensuring job template: ${name}"
  awx_idempotent job_templates create \
    --name "${name}" \
    --job_type "run" \
    --inventory "${INV_ID}" \
    --project "${PROJ_ID}" \
    --playbook "${playbook}" \
    --extra_vars "${extra_vars}" \
    --verbosity 1 \
    --ask_variables_on_launch true
}

create_template "Patch Management"    "playbooks/patch_management.yml"   '{"cve_id":"","skip_reboot":false}'
create_template "Config Drift Detect" "playbooks/config_drift.yml"       '{"drift_fix":false}'
create_template "Config Drift Fix"    "playbooks/config_drift.yml"       '{"drift_fix":true}'
create_template "Security Hardening"  "playbooks/security_hardening.yml" '{}'
create_template "User Provisioning"   "playbooks/user_provisioning.yml"  '{}'

# 5. Emergency patch survey
step "Attaching survey to 'Patch Management' template"

EMERGENCY_ID=$(get_id job_templates "Patch Management")
if [[ -z "${EMERGENCY_ID}" ]]; then
  echo "ERROR: Could not resolve job template ID for 'Patch Management'" >&2
  exit 1
fi

awx_idempotent job_templates modify "${EMERGENCY_ID}" \
  --survey_enabled true \
  --survey_spec "$(cat awx/surveys/emergency_patch.json)"

# 6. Schedules
log "Creating scheduled runs"

PATCH_TMPL_ID=$(get_id job_templates "Patch Management")
DRIFT_TMPL_ID=$(get_id job_templates "Config Drift Detect")
HARD_TMPL_ID=$(get_id job_templates "Security Hardening")

# Nightly patch check — 02:00 UTC daily
awx_idempotent schedules create \
  --name "Nightly Patch Check" \
  --unified_job_template "${PATCH_TMPL_ID}" \
  --rrule "DTSTART:20240101T020000Z RRULE:FREQ=DAILY;INTERVAL=1" \
  --extra_data '{"cve_id":"","skip_reboot":false}'

# Weekly drift scan — Sundays 03:00 UTC
awx_idempotent schedules create \
  --name "Weekly Drift Scan" \
  --unified_job_template "${DRIFT_TMPL_ID}" \
  --rrule "DTSTART:20240101T030000Z RRULE:FREQ=WEEKLY;BYDAY=SU" \
  --extra_data '{"drift_fix":false}'

# Weekly hardening audit — Sundays 04:00 UTC
awx_idempotent schedules create \
  --name "Weekly Hardening Audit" \
  --unified_job_template "${HARD_TMPL_ID}" \
  --rrule "DTSTART:20240101T040000Z RRULE:FREQ=WEEKLY;BYDAY=SU" \
  --extra_data '{}'

log "AWX configuration complete."
echo "    Job templates, schedules, and emergency patch survey are in place."
echo "    Open ${AWX_HOST} to verify."
