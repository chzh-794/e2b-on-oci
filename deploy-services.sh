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
NOMAD_REGION="${NOMAD_REGION:-}"

# Auto-detect region from server pool metadata if not provided; fall back to Ashburn
if [[ -z "${NOMAD_REGION}" ]]; then
  NOMAD_REGION=$(ssh "${BASTION_SSH_OPTS[@]}" ${SSH_USER}@${BASTION_HOST} \
    "curl -sf -H 'Authorization: Bearer Oracle' http://169.254.169.254/opc/v2/instance/ | jq -r '.canonicalRegionName // .region // empty'") || true
  NOMAD_REGION=${NOMAD_REGION:-us-ashburn-1}
fi

NOMAD_STAGE_DIR=$(mktemp -d)
cleanup_stage() {
  rm -rf "${NOMAD_STAGE_DIR}"
}
trap cleanup_stage EXIT

cp -R "${NOMAD_DIR}/." "${NOMAD_STAGE_DIR}/"
python - "$NOMAD_STAGE_DIR" "$NOMAD_REGION" <<'PY'
import sys, pathlib
root, region = pathlib.Path(sys.argv[1]), sys.argv[2]
for path in root.rglob("*"):
    if not path.is_file():
        continue
    data = path.read_text(encoding="utf-8")
    if "__REGION__" in data:
        path.write_text(data.replace("__REGION__", region), encoding="utf-8")
PY

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║       Deploying E2B Services via Nomad                    ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Stage HCLs on bastion (control node for submission)
echo -e "${YELLOW}Copying Nomad job definitions to Bastion...${NC}"
tar -C "${NOMAD_STAGE_DIR}" -czf - . \
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

ssh "${BASTION_SSH_OPTS[@]}" ${SSH_USER}@${BASTION_HOST} <<EOF
export NOMAD_BIN="${NOMAD_BIN_REMOTE}"
export NOMAD_ADDR="${NOMAD_ADDR_REMOTE}"
cd ~/nomad
# Always stop-purge-run to ensure clean state and pick up new binaries, config, and infrastructure changes
# Stop job first to allow graceful shutdown (which removes lock file)
if \$NOMAD_BIN job status orchestrator >/dev/null 2>&1; then
  echo "Stopping and purging existing orchestrator job..."
  \$NOMAD_BIN job stop -purge orchestrator || true
  sleep 3
fi
EOF

# Clear orchestrator lock file AFTER stopping job (safety measure for crashed processes)
# Lock file is removed on graceful shutdown, but persists if orchestrator crashed
# Also ensure root is in disk,kvm groups for NBD device access (POC fix from POC_SUMMARY.md)
# IMPORTANT: Nomad raw_exec driver doesn't pass through supplementary groups, so we create
# a wrapper script that explicitly sets groups using 'sg' command
if [[ -n "${CLIENT_POOL_PRIVATE}" ]]; then
  echo "Clearing orchestrator lock file and ensuring NBD device access on client pool..."
  ssh "${SSH_OPTS[@]}" ${SSH_USER}@${CLIENT_POOL_PRIVATE} <<'ENDSSH'
    sudo rm -f /opt/e2b/runtime/orchestrator.lock && echo 'Lock file cleared' || true
    # Add root (Nomad agent user) to disk and kvm groups for NBD device access
    # This is required for orchestrator to access /dev/nbd* devices in Nomad raw_exec allocations
    # POC fix from POC_SUMMARY.md section "### 5. NBD Device Permissions"
    sudo usermod -a -G disk,kvm root || true
    echo 'NBD device access configured'
    # Create wrapper script that runs orchestrator with proper groups
    # Nomad raw_exec doesn't pass through supplementary groups, so we use 'sg' to switch groups
    sudo tee /opt/e2b/bin/orchestrator-wrapper.sh >/dev/null <<'WRAPPER'
#!/bin/bash
# Wrapper script to run orchestrator with disk/kvm groups
# Nomad raw_exec driver doesn't pass through supplementary groups, so we use 'sg' to switch
cd /opt/e2b
set -a
source orchestrator.env
set +a
# Use 'sg' to switch to disk group (which has access to /dev/nbd* devices)
# The -c flag runs the command in a new shell with the specified group
exec sg disk -c "./bin/orchestrator --port 5008 --proxy-port 5007"
WRAPPER
    sudo chmod +x /opt/e2b/bin/orchestrator-wrapper.sh
    echo 'Orchestrator wrapper script created'
ENDSSH
fi

ssh "${BASTION_SSH_OPTS[@]}" ${SSH_USER}@${BASTION_HOST} <<EOF
export NOMAD_BIN="${NOMAD_BIN_REMOTE}"
export NOMAD_ADDR="${NOMAD_ADDR_REMOTE}"
cd ~/nomad
echo "Deploying orchestrator job..."
\$NOMAD_BIN job run orchestrator.hcl
sleep 3
echo ""
echo "Orchestrator deployment status:"
\$NOMAD_BIN job status orchestrator
EOF
echo -e "${GREEN}✓ Orchestrator deployed${NC}"
echo ""

# Deploy Template Manager (as systemd service to bypass Nomad loop device restrictions)
echo -e "${GREEN}Step 2: Deploying Template Manager (systemd service)${NC}"
if [[ -z "${CLIENT_POOL_PRIVATE}" ]]; then
  echo -e "${RED}Error: CLIENT_POOL_PRIVATE must be set in deploy.env${NC}" >&2
  exit 1
fi

# Stop and purge Nomad job if it exists (template-manager now runs as systemd service)
# This ensures no conflicts between Nomad job and systemd service
ssh "${BASTION_SSH_OPTS[@]}" ${SSH_USER}@${BASTION_HOST} <<EOF
export NOMAD_BIN="${NOMAD_BIN_REMOTE}"
export NOMAD_ADDR="${NOMAD_ADDR_REMOTE}"
if \$NOMAD_BIN job status template-manager >/dev/null 2>&1; then
  echo "Stopping and purging existing template-manager Nomad job (now using systemd service)..."
  \$NOMAD_BIN job stop -purge template-manager || true
  sleep 2
  # Verify job is purged
  if \$NOMAD_BIN job status template-manager >/dev/null 2>&1; then
    echo "Warning: template-manager Nomad job still exists after purge attempt" >&2
  else
    echo "✓ template-manager Nomad job purged successfully"
  fi
fi
EOF

# Install and start systemd service on client pool
echo "Installing template-manager systemd service on client pool..."
ssh "${SSH_OPTS[@]}" ${SSH_USER}@${CLIENT_POOL_PRIVATE} <<'EOF'
set -e
# Install systemd service file (idempotent - safe to run multiple times)
sudo mkdir -p /etc/systemd/system
cat <<'SERVICE' | sudo tee /etc/systemd/system/template-manager.service >/dev/null
[Unit]
Description=E2B Template Manager
Documentation=https://github.com/e2b-dev/infra
After=network-online.target consul.service
Wants=network-online.target
Requires=consul.service

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/opt/e2b
EnvironmentFile=-/opt/e2b/template-manager.env
# NODE_ID will be set dynamically from instance metadata or hostname
ExecStartPre=/bin/bash -c 'if [ -z "$NODE_ID" ]; then export NODE_ID=$(curl -sSL -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v2/instance/id 2>/dev/null || hostname); fi'
ExecStart=/bin/bash -c 'cd /opt/e2b && export NODE_ID=${NODE_ID:-$(hostname)} && set -a && source template-manager.env && set +a && exec ./bin/template-manager --port 5009 --proxy-port 15007'
ExecReload=/bin/kill -HUP $MAINPID
KillSignal=SIGTERM
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536

# Security: Allow loop device operations (needed for template builds)
# No PrivateDevices - we need /dev/loop-control access
# No NoNewPrivileges - we may need capability escalation

[Install]
WantedBy=multi-user.target
SERVICE

# Create Consul service definition for template-manager
# Consul agent uses -config-dir=/opt/consul/config
sudo mkdir -p /opt/consul/config
cat <<'CONSUL_SERVICE' | sudo tee /opt/consul/config/template-manager.json >/dev/null
{
  "service": {
    "name": "template-manager",
    "port": 5009,
    "tags": ["grpc"],
    "check": {
      "grpc": "127.0.0.1:5009",
      "interval": "10s",
      "timeout": "3s"
    }
  }
}
CONSUL_SERVICE

# Set proper ownership and reload Consul to pick up new service definition
sudo chown consul:consul /opt/consul/config/template-manager.json 2>/dev/null || sudo chown root:root /opt/consul/config/template-manager.json
sudo systemctl reload consul || sudo systemctl restart consul || true
sleep 2

# Reload systemd and enable/start service (idempotent)
sudo systemctl daemon-reload
sudo systemctl stop template-manager || true
sudo systemctl enable template-manager || true  # Safe if already enabled
sudo systemctl start template-manager || true   # Will fail gracefully if binary doesn't exist yet
sleep 2
echo "Template Manager systemd service status:"
sudo systemctl status template-manager --no-pager -l || true
EOF
echo -e "${GREEN}✓ Template Manager deployed as systemd service${NC}"
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
# NOTE: template-manager runs as systemd service, not Nomad job
for job in orchestrator api client-proxy; do
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
