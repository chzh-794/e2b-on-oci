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
BASTION_HOST=${BASTION_HOST:-}

KNOWN_HOSTS_FILE=${KNOWN_HOSTS_FILE:-$HOME/.ssh/known_hosts}
mkdir -p "$(dirname "${KNOWN_HOSTS_FILE}")"
touch "${KNOWN_HOSTS_FILE}"
if [[ -n "${BASTION_HOST}" ]]; then
  if ! ssh-keygen -F "${BASTION_HOST}" -f "${KNOWN_HOSTS_FILE}" >/dev/null 2>&1; then
    ssh-keyscan -H "${BASTION_HOST}" >> "${KNOWN_HOSTS_FILE}" 2>/dev/null || true
  fi
fi

if [[ -z "${SERVER_POOL_PUBLIC}" ]] || [[ ${SERVER_POOL_PUBLIC} == REPLACE_* ]]; then
  echo "SERVER_POOL_PUBLIC must be set in deploy.env"
  exit 1
fi
if [[ -z "${BASTION_HOST}" ]] || [[ ${BASTION_HOST} == REPLACE_* ]]; then
  echo "BASTION_HOST must be set in deploy.env"
  exit 1
fi

SSH_BASE_OPTS=(-i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile="${KNOWN_HOSTS_FILE}" -o IdentitiesOnly=yes)
if [[ -n "${BASTION_HOST}" ]]; then
  # Use ProxyCommand instead of ProxyJump so we can pass -i to the proxy SSH command
  SSH_OPTS=("${SSH_BASE_OPTS[@]}" -o ProxyCommand="ssh -i ${SSH_KEY} -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=${KNOWN_HOSTS_FILE} -W %h:%p ${SSH_USER}@${BASTION_HOST}")
else
  SSH_OPTS=("${SSH_BASE_OPTS[@]}")
fi

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

NOMAD_DIR="${SCRIPT_DIR}/nomad"

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║       Deploying E2B Services via Nomad                    ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Copy Nomad job files to server
echo -e "${YELLOW}Copying Nomad job definitions to Server Pool...${NC}"
ssh "${SSH_OPTS[@]}" ${SSH_USER}@${SERVER_POOL_PUBLIC} "mkdir -p ~/nomad"
scp "${SSH_OPTS[@]}" ${NOMAD_DIR}/*.hcl ${SSH_USER}@${SERVER_POOL_PUBLIC}:~/nomad/
echo -e "${GREEN}✓ Job definitions copied${NC}"
echo ""

# Deploy Orchestrator (system job - runs on all client nodes)
echo -e "${GREEN}Step 1: Deploying Orchestrator${NC}"
ssh "${SSH_OPTS[@]}" ${SSH_USER}@${SERVER_POOL_PUBLIC} << 'ENDSSH'
cd ~/nomad
/usr/local/bin/nomad job stop -purge orchestrator >/dev/null 2>&1 || true
/usr/local/bin/nomad job run orchestrator.hcl
sleep 3
echo ""
echo "Orchestrator deployment status:"
/usr/local/bin/nomad job status orchestrator
ENDSSH
echo -e "${GREEN}✓ Orchestrator deployed${NC}"
echo ""

# Deploy API
echo -e "${GREEN}Step 2: Deploying E2B API${NC}"
ssh "${SSH_OPTS[@]}" ${SSH_USER}@${SERVER_POOL_PUBLIC} << 'ENDSSH'
cd ~/nomad
/usr/local/bin/nomad job stop -purge api >/dev/null 2>&1 || true
/usr/local/bin/nomad job run api.hcl
sleep 3
echo ""
echo "API deployment status:"
/usr/local/bin/nomad job status api
ENDSSH
echo -e "${GREEN}✓ E2B API deployed${NC}"
echo ""

# Deploy Client Proxy
echo -e "${GREEN}Step 3: Deploying Client Proxy${NC}"
ssh "${SSH_OPTS[@]}" ${SSH_USER}@${SERVER_POOL_PUBLIC} << 'ENDSSH'
cd ~/nomad
/usr/local/bin/nomad job stop -purge client-proxy >/dev/null 2>&1 || true
/usr/local/bin/nomad job run client-proxy.hcl
sleep 3
echo ""
echo "Client Proxy deployment snapshot (expected unhealthy without OTEL):"
/usr/local/bin/nomad job status -short client-proxy || true
ENDSSH
echo -e "${GREEN}✓ Client Proxy deployed${NC}"
echo ""

# Deploy Template Manager
echo -e "${GREEN}Step 4: Deploying Template Manager${NC}"
ssh "${SSH_OPTS[@]}" ${SSH_USER}@${SERVER_POOL_PUBLIC} << 'ENDSSH'
cd ~/nomad
/usr/local/bin/nomad job stop -purge template-manager >/dev/null 2>&1 || true
/usr/local/bin/nomad job run template-manager.hcl
sleep 3
echo ""
echo "Template Manager deployment status:"
/usr/local/bin/nomad job status template-manager
ENDSSH
echo -e "${GREEN}✓ Template Manager deployed${NC}"
echo ""

# Verify all services
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Verifying All Services${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo ""

ssh "${SSH_OPTS[@]}" ${SSH_USER}@${SERVER_POOL_PUBLIC} << 'ENDSSH'
echo "=== All Nomad Jobs ==="
/usr/local/bin/nomad job status

echo ""
echo "=== Consul Services ==="
/usr/local/bin/consul catalog services
ENDSSH

# Summary
echo ""
echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║       All Services Deployed!                               ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}✓ Orchestrator running on Client Pool${NC}"
echo -e "${GREEN}✓ E2B API running on API Pool${NC}"
echo -e "${GREEN}✓ Client Proxy running on API Pool${NC}"
echo ""
echo -e "${YELLOW}Access Points:${NC}"
echo "  Nomad UI:  http://${SERVER_POOL_PUBLIC}:4646"
echo "  Consul UI: http://${SERVER_POOL_PUBLIC}:8500"
echo "  E2B API:   http://${API_POOL_PUBLIC}:8080"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo "1. Test API endpoint: curl http://${API_POOL_PUBLIC}:8080/health"
echo "2. Create a test template"
echo "3. Test sandbox lifecycle"
echo ""

