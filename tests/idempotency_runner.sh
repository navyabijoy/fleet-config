#!/usr/bin/env bash
# Proves idempotency for all fleet-config playbooks.
#
# Usage:
#   chmod +x tests/idempotency_runner.sh
#   ./tests/idempotency_runner.sh
#
# Requires:
#   - ANSIBLE_PRIVATE_KEY_FILE exported (path to fleet_key.pem)
#   - At least one host reachable in the dynamic inventory (env:staging tagged EC2)
#   - FLEET_TAG_KEY and FLEET_TAG_VALUE set if non-default
#
# Exit codes:
#   0 — All playbooks idempotent (changed=0 on run 2)
#   1 — One or more playbooks NOT idempotent

set -euo pipefail

RESULTS_DIR="tests/idempotency_results"
mkdir -p "${RESULTS_DIR}"

TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
PASS_COUNT=0
FAIL_COUNT=0

declare -A PLAYBOOKS
PLAYBOOKS=(
  ["security_hardening"]="playbooks/security_hardening.yml"
  ["user_provisioning"]="playbooks/user_provisioning.yml"
  ["patch_management"]="playbooks/patch_management.yml"
  ["config_drift"]="playbooks/config_drift.yml"
)

# Separate ordering for config_drift — needs hardening applied first
PLAYBOOK_ORDER=(security_hardening user_provisioning patch_management config_drift)

run_playbook() {
  local name="$1"
  local path="$2"
  local run_num="$3"
  local log_file="${RESULTS_DIR}/${name}_run${run_num}_${TIMESTAMP}.log"

  echo "  Running ${path} (run ${run_num})..."
  ansible-playbook "${path}" \
    -i inventory/aws_ec2.py \
    --diff \
    -v \
    2>&1 | tee "${log_file}"

  echo "${log_file}"
}

extract_changed() {
  local log_file="$1"
  grep -oP 'changed=\K[0-9]+' "${log_file}" | tail -1
}

extract_failed() {
  local log_file="$1"
  grep -oP 'failed=\K[0-9]+' "${log_file}" | tail -1
}

echo "============================================================"
echo "  Fleet Config — Idempotency Proof"
echo "  Timestamp: ${TIMESTAMP}"
echo "============================================================"
echo ""

for name in "${PLAYBOOK_ORDER[@]}"; do
  path="${PLAYBOOKS[$name]}"
  echo ">>> Playbook: ${name} (${path})"
  echo "------------------------------------------------------------"

  # Run 1: establish baseline state
  log1=$(run_playbook "${name}" "${path}" 1)
  changed1=$(extract_changed "${log1}")
  failed1=$(extract_failed "${log1}")
  echo "    Run 1: changed=${changed1}, failed=${failed1}"

  if [[ "${failed1}" != "0" ]]; then
    echo "    WARN: Run 1 had failures — idempotency test skipped."
    ((FAIL_COUNT++))
    continue
  fi

  # Run 2: assert idempotency
  log2=$(run_playbook "${name}" "${path}" 2)
  changed2=$(extract_changed "${log2}")
  failed2=$(extract_failed "${log2}")
  echo "    Run 2: changed=${changed2}, failed=${failed2}"

  if [[ "${changed2}" == "0" && "${failed2}" == "0" ]]; then
    echo "    PASS ✓  ${name} is idempotent"
    ((PASS_COUNT++))
  else
    echo "    FAIL ✗  ${name} is NOT idempotent (changed=${changed2} on run 2)"
    ((FAIL_COUNT++))
  fi

  echo ""
done

echo "============================================================"
echo "  Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
echo "  Logs saved to: ${RESULTS_DIR}/"
echo "============================================================"

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
  exit 1
fi

exit 0
