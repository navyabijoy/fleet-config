# Idempotency Results

Pre-committed sample logs showing zero changes on second run.
Real logs from EC2 t2.micro (Ubuntu 22.04) instances will be added here
after initial deployment.

File naming convention:
  <playbook_name>_run<N>_<YYYYMMDDTHHMMSSZ>.log

Expected second-run summary line for each playbook:
  ok=N  changed=0  unreachable=0  failed=0  skipped=N  rescued=0  ignored=0
