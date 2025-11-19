#!/bin/bash
# Deploy E2B services via Nomad

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/deploy.env"

if [[ -f "${CONFIG_FILE}" ]]; then
  echo "Loading deployment configuration from ${CONFIG_FILE}"
  set -a
  source "${CONFIG_FILE}"
  set +a
else
  echo "Missing ${CONFIG_FILE}. Copy deploy.env.example to deploy.env and fill in your OCI values."
  exit 1
fi

SSH_USER=${SSH_USER:-ubuntu}
SSH_KEY=${SSH_KEY:-$HOME/.ssh/e2b_id_rsa}
SSH_KEY=${SSH_KEY/#\~/$HOME}
SERVER_POOL_PUBLIC=${SERVER_POOL_PUBLIC:-$SERVER_POOL_PRIVATE}
SERVER_POOL_PRIVATE=${SERVER_POOL_PRIVATE:-$SERVER_POOL_PUBLIC}
API_POOL_PUBLIC=${API_POOL_PUBLIC:-}
API_POOL_PRIVATE=${API_POOL_PRIVATE:-$API_POOL_PUBLIC}
BASTION_HOST=${BASTION_HOST:-}

KNOWN_HOSTS_FILE=${KNOWN_HOSTS_FILE:-$HOME/.ssh/known_hosts}
mkdir -p "$(dirname "${KNOWN_HOSTS_FILE}")"
touch "${KNOWN_HOSTS_FILE}"
ssh-keygen -R "${SERVER_POOL_PRIVATE}" >/dev/null 2>&1 || true
ssh-keygen -R "${API_POOL_PRIVATE}" >/dev/null 2>&1 || true
if [[ -n "${BASTION_HOST}" ]]; then
  if ! ssh-keygen -F "${BASTION_HOST}" -f "${KNOWN_HOSTS_FILE}" >/dev/null 2>&1; then
    ssh-keyscan -H "${BASTION_HOST}" >> "${KNOWN_HOSTS_FILE}" 2>/dev/null || true
  fi
fi

if [[ -z "${SERVER_POOL_PRIVATE}" ]] || [[ ${SERVER_POOL_PRIVATE} == REPLACE_* ]]; then
  echo "SERVER_POOL_PRIVATE must be set in deploy.env"
  exit 1
fi
if [[ -z "${BASTION_HOST}" ]] || [[ ${BASTION_HOST} == REPLACE_* ]]; then
  echo "BASTION_HOST must be set in deploy.env"
  exit 1
fi
CONTROL_HOST=${API_POOL_PRIVATE:-$API_POOL_PUBLIC}
if [[ -z "${CONTROL_HOST}" ]] || [[ ${CONTROL_HOST} == REPLACE_* ]]; then
  echo "API_POOL_PRIVATE (or API_POOL_PUBLIC) must be set in deploy.env"
  exit 1
fi

SSH_BASE_OPTS=(-i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile="${KNOWN_HOSTS_FILE}" -o IdentitiesOnly=yes)
# Direct SSH to bastion
BASTION_SSH_OPTS=("${SSH_BASE_OPTS[@]}")
# SSH via bastion to private hosts
SSH_OPTS=("${SSH_BASE_OPTS[@]}" -o ProxyCommand="ssh -i ${SSH_KEY} -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=${KNOWN_HOSTS_FILE} -W %h:%p ${SSH_USER}@${BASTION_HOST}")

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

NOMAD_DIR="${SCRIPT_DIR}/nomad"

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║       Deploying E2B Services via Nomad                    ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Stage HCLs on bastion (control node for submission)
echo -e "${YELLOW}Copying Nomad job definitions to Bastion...${NC}"
tar -C "${NOMAD_DIR}" -czf - . \
  | ssh "${BASTION_SSH_OPTS[@]}" ${SSH_USER}@${BASTION_HOST} 'rm -rf ~/nomad && mkdir -p ~/nomad && tar -xzf - -C ~/nomad'
echo -e "${GREEN}✓ Job definitions copied to Bastion${NC}"
echo ""

# Deploy Orchestrator (system job - runs on all client nodes)
echo -e "${GREEN}Step 1: Deploying Orchestrator${NC}"
NOMAD_BIN_REMOTE=$(ssh "${BASTION_SSH_OPTS[@]}" ${SSH_USER}@${BASTION_HOST} 'if command -v nomad >/dev/null 2>&1; then command -v nomad; elif [ -x /opt/nomad/bin/nomad ]; then echo /opt/nomad/bin/nomad; elif [ -x /usr/local/bin/nomad ]; then echo /usr/local/bin/nomad; else echo ""; fi')
if [[ -z "${NOMAD_BIN_REMOTE}" ]] || [[ "${NOMAD_BIN_REMOTE}" == "/usr/bin/which" ]]; then
  # Install lightweight nomad if missing
  ssh "${BASTION_SSH_OPTS[@]}" ${SSH_USER}@${BASTION_HOST} 'set -e; ARCH=linux_amd64; VER=1.8.0; TMP=$(mktemp -d); cd "$TMP"; curl -sSL -o nomad.zip https://releases.hashicorp.com/nomad/${VER}/nomad_${VER}_${ARCH}.zip; unzip -q nomad.zip; sudo install -m 0755 nomad /usr/local/bin/nomad; rm -rf "$TMP"'
  NOMAD_BIN_REMOTE="/usr/local/bin/nomad"
fi
NOMAD_ADDR_REMOTE="http://${SERVER_POOL_PRIVATE}:4646"

# Clear orchestrator lock file on client pool before redeploying
if [[ -n "${CLIENT_POOL_PRIVATE}" ]]; then
  echo "Clearing orchestrator lock file on client pool..."
  ssh "${SSH_OPTS[@]}" ${SSH_USER}@${CLIENT_POOL_PRIVATE} "sudo rm -f /opt/e2b/runtime/orchestrator.lock && echo 'Lock file cleared'" || true
fi

ssh "${BASTION_SSH_OPTS[@]}" ${SSH_USER}@${BASTION_HOST} <<EOF
export NOMAD_BIN="${NOMAD_BIN_REMOTE}"
export NOMAD_ADDR="${NOMAD_ADDR_REMOTE}"
cd ~/nomad
# Always stop-purge-run to ensure clean state and pick up new binaries, config, and infrastructure changes
if \$NOMAD_BIN job status orchestrator >/dev/null 2>&1; then
  echo "Stopping and purging existing orchestrator job..."
  \$NOMAD_BIN job stop -purge orchestrator || true
  sleep 2
fi
echo "Deploying orchestrator job..."
\$NOMAD_BIN job run orchestrator.hcl
sleep 3
echo ""
echo "Orchestrator deployment status:"
\$NOMAD_BIN job status orchestrator
EOF
echo -e "${GREEN}✓ Orchestrator deployed${NC}"
echo ""

# Deploy Template Manager
echo -e "${GREEN}Step 2: Deploying Template Manager${NC}"
ssh "${BASTION_SSH_OPTS[@]}" ${SSH_USER}@${BASTION_HOST} <<EOF
export NOMAD_BIN="${NOMAD_BIN_REMOTE}"
export NOMAD_ADDR="${NOMAD_ADDR_REMOTE}"
cd ~/nomad
# Always stop-purge-run to ensure clean state and pick up new binaries, config, and infrastructure changes (e.g., disk group for loop devices)
if \$NOMAD_BIN job status template-manager >/dev/null 2>&1; then
  echo "Stopping and purging existing template-manager job..."
  \$NOMAD_BIN job stop -purge template-manager || true
  sleep 2
fi
echo "Deploying template-manager job..."
\$NOMAD_BIN job run template-manager.hcl
sleep 3
echo ""
echo "Template Manager deployment status:"
\$NOMAD_BIN job status template-manager
EOF
echo -e "${GREEN}✓ Template Manager deployed${NC}"
echo ""

# Wait for template-manager to register in Consul before starting API (up to 90s)
echo -e "${YELLOW}Waiting for template-manager to register in Consul...${NC}"
ssh "${BASTION_SSH_OPTS[@]}" ${SSH_USER}@${BASTION_HOST} <<EOF
set -e
CONSUL_ADDR="http://${SERVER_POOL_PRIVATE}:8500"
tries=0
while ! curl -sf "\${CONSUL_ADDR}/v1/catalog/service/template-manager" | jq -e 'length>0' >/dev/null 2>&1; do
  tries=\$((tries+1))
  if [ "\$tries" -ge 30 ]; then
    echo "template-manager not registered in Consul within timeout." >&2
    exit 1
  fi
  sleep 3
done
echo "template-manager is registered in Consul."
EOF

# Deploy E2B API (after template-manager is available)
echo -e "${GREEN}Step 3: Deploying E2B API${NC}"
ssh "${BASTION_SSH_OPTS[@]}" ${SSH_USER}@${BASTION_HOST} <<EOF
export NOMAD_BIN="${NOMAD_BIN_REMOTE}"
export NOMAD_ADDR="${NOMAD_ADDR_REMOTE}"
cd ~/nomad
# Always stop-purge-run to ensure clean state and pick up new binaries, config, and infrastructure changes
if \$NOMAD_BIN job status api >/dev/null 2>&1; then
  echo "Stopping and purging existing api job..."
  \$NOMAD_BIN job stop -purge api || true
  sleep 2
fi
echo "Deploying api job..."
\$NOMAD_BIN job run api.hcl
sleep 3
echo ""
echo "API deployment status:"
\$NOMAD_BIN job status api
EOF
echo -e "${GREEN}✓ E2B API deployed${NC}"
echo ""

# Deploy Client Proxy
echo -e "${GREEN}Step 4: Deploying Client Proxy${NC}"
ssh "${BASTION_SSH_OPTS[@]}" ${SSH_USER}@${BASTION_HOST} <<EOF
set -e
export NOMAD_BIN="${NOMAD_BIN_REMOTE}"
export NOMAD_ADDR="${NOMAD_ADDR_REMOTE}"
cd ~/nomad
# Always stop-purge-run to ensure clean state and pick up new binaries, config, and infrastructure changes
if \$NOMAD_BIN job status client-proxy >/dev/null 2>&1; then
  echo "Stopping and purging existing client-proxy job..."
  \$NOMAD_BIN job stop -purge client-proxy || true
  sleep 2
fi
echo "Deploying client-proxy job..."
\$NOMAD_BIN job run client-proxy.hcl
echo ""
echo "Waiting for client-proxy to be placed (up to 60s)..."
tries=0
while [ \$tries -lt 20 ]; do
  if \$NOMAD_BIN job status -json client-proxy >/tmp/job-client-proxy.json 2>/dev/null; then
    running=\$(python3 - <<'PY'
import json
data = json.load(open("/tmp/job-client-proxy.json", "r"))
# nomad job status -json returns a list, get first element
if isinstance(data, list):
    data = data[0] if data else {}
# Summary is nested: data['Summary']['Summary']['task-group-name']
summary = data.get("Summary", {})
task_group_summary = summary.get("Summary", {})
# Get the first task group's stats
tg = next(iter(task_group_summary.values()), {}) if task_group_summary else {}
print(tg.get("Running", 0))
PY
)
    if [ "\$running" -gt 0 ]; then
      echo "client-proxy is placed (Running=\$running)"
      break
    fi
  fi
  tries=\$((tries+1))
  sleep 3
done
if [ \$tries -ge 20 ]; then
  echo "WARNING: client-proxy not placed within timeout" >&2
fi
echo ""
echo "Client Proxy deployment snapshot (expected unhealthy without OTEL):"
\$NOMAD_BIN job status -short client-proxy || true
EOF
echo -e "${GREEN}✓ Client Proxy deployed${NC}"
echo ""

# Verify all services and print a final summary
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Verifying All Services${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo ""

ssh "${BASTION_SSH_OPTS[@]}" ${SSH_USER}@${BASTION_HOST} <<EOF
set -e
export NOMAD_ADDR="${NOMAD_ADDR_REMOTE}"
export NOMAD_BIN="${NOMAD_BIN_REMOTE}"

overall_rc=0

echo "=== Nomad Job Summary (critical jobs) ==="
for job in orchestrator template-manager api client-proxy; do
  echo ""
  echo "Job: \${job}"
  
  # Check if job exists and get status
  job_missing=false
  job_running=0
  if ! \$NOMAD_BIN job status -json "\${job}" >/tmp/job-\${job}.json 2>/dev/null; then
    job_missing=true
    echo "  WARNING: job \${job} not found in Nomad. Attempting to redeploy..."
  else
    job_running=\$(python3 - "\${job}" <<'PY'
import json, sys
job = sys.argv[1]
with open(f"/tmp/job-{job}.json", "r") as f:
    data = json.load(f)
# nomad job status -json returns a list, get first element
if isinstance(data, list):
    data = data[0] if data else {}
# Summary is nested: data['Summary']['Summary']['task-group-name']
summary = data.get("Summary", {})
task_group_summary = summary.get("Summary", {})
# Get the first task group's stats
tg = next(iter(task_group_summary.values()), {}) if task_group_summary else {}
running = tg.get("Running", 0)
failed = tg.get("Failed", 0)
print(f"{running}")
PY
)
    if [ "\${job_running}" -le 0 ]; then
      echo "  WARNING: job \${job} has no running allocations (Running=\${job_running}). Attempting to redeploy..."
      job_missing=true
    fi
  fi
  
  # Auto-redeploy if missing or not running
  if [ "\${job_missing}" = "true" ]; then
    echo "  Redeploying \${job}..."
    cd ~/nomad
    # Always stop-purge-run to ensure clean state
    if \$NOMAD_BIN job status "\${job}" >/dev/null 2>&1; then
      \$NOMAD_BIN job stop -purge "\${job}" || true
      sleep 2
    fi
    \$NOMAD_BIN job run "\${job}.hcl" || {
      echo "  ERROR: Failed to deploy \${job}"
      overall_rc=1
      continue
    }
    sleep 5
    # Re-check after redeploy
    if ! \$NOMAD_BIN job status -json "\${job}" >/tmp/job-\${job}.json 2>/dev/null; then
      echo "  ERROR: job \${job} still not found after redeploy."
      overall_rc=1
      continue
    fi
    job_running=\$(python3 - "\${job}" <<'PY'
import json, sys
job = sys.argv[1]
with open(f"/tmp/job-{job}.json", "r") as f:
    data = json.load(f)
# nomad job status -json returns a list, get first element
if isinstance(data, list):
    data = data[0] if data else {}
# Summary is nested: data['Summary']['Summary']['task-group-name']
summary = data.get("Summary", {})
task_group_summary = summary.get("Summary", {})
# Get the first task group's stats
tg = next(iter(task_group_summary.values()), {}) if task_group_summary else {}
running = tg.get("Running", 0)
print(f"{running}")
PY
)
  fi
  
  # Final status check
  python3 - "\${job}" <<'PY'
import json, sys
job = sys.argv[1]
with open(f"/tmp/job-{job}.json", "r") as f:
    data = json.load(f)
# nomad job status -json returns a list, get first element
if isinstance(data, list):
    data = data[0] if data else {}
# Summary is nested: data['Summary']['Summary']['task-group-name']
summary = data.get("Summary", {})
task_group_summary = summary.get("Summary", {})
# Get the first task group's stats
tg = next(iter(task_group_summary.values()), {}) if task_group_summary else {}
running = tg.get("Running", 0)
failed = tg.get("Failed", 0)
print(f"  Running={running} Failed={failed}")
if running <= 0:
    print(f"  CRITICAL: job {job} has no running allocations after redeploy attempt.")
    sys.exit(1)
PY
  rc=$?
  if [ \$rc -ne 0 ]; then
    overall_rc=1
  fi
done

echo ""
echo "=== All Nomad Jobs ==="
\$NOMAD_BIN job status

exit \$overall_rc
EOF

rc=$?

# Query Consul services from API pool (outside the bastion heredoc)
echo ""
echo "=== Consul Services ==="
if ssh "${SSH_OPTS[@]}" ${SSH_USER}@${CONTROL_HOST} 'curl -sf http://127.0.0.1:8500/v1/catalog/services 2>/dev/null | jq -r "keys[]" | sort' 2>/dev/null; then
  echo "✓ Consul services listed"
else
  echo "⚠ Consul not available or not responding (querying from API pool)"
fi

echo ""
echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
if [[ $rc -eq 0 ]]; then
  echo -e "${BLUE}║   All Services Deployed and Running (critical jobs OK)     ║${NC}"
else
  echo -e "${BLUE}║   Service Deployment Completed WITH FAILURES               ║${NC}"
fi
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Access Points:${NC}"
echo "  Nomad UI:  http://${SERVER_POOL_PUBLIC}:4646"
echo "  Consul UI: http://${SERVER_POOL_PUBLIC}:8500"
echo "  E2B API:   http://${API_POOL_PUBLIC}:8080"
echo ""

if [[ $rc -ne 0 ]]; then
  echo -e "${RED}One or more critical Nomad jobs are not running. See summary above.${NC}"
  exit $rc
fi

# Note: API credentials are automatically refreshed by validate-api.sh when needed
# If you need credentials before running validate-api.sh, run: ./scripts/export-api-creds.sh

