#!/bin/bash
# Test if client-proxy can reach orchestrator

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../deploy.env"

if [[ -f "${CONFIG_FILE}" ]]; then
  set -a
  source "${CONFIG_FILE}"
  set +a
else
  echo "Missing ${CONFIG_FILE}"
  exit 1
fi

SSH_USER=${SSH_USER:-ubuntu}
SSH_KEY=${SSH_KEY:-$HOME/.ssh/e2b_id_rsa}
SSH_KEY=${SSH_KEY/#\~/$HOME}

API_TARGET=${API_POOL_PRIVATE:-$API_POOL_PUBLIC}
CLIENT_TARGET=${CLIENT_POOL_PRIVATE:-$CLIENT_POOL_PUBLIC}
BASTION=${BASTION_HOST}

KNOWN_HOSTS_FILE=${KNOWN_HOSTS_FILE:-$HOME/.ssh/known_hosts}
mkdir -p "$(dirname "${KNOWN_HOSTS_FILE}")"
touch "${KNOWN_HOSTS_FILE}"
if ! ssh-keygen -F "${BASTION_HOST}" -f "${KNOWN_HOSTS_FILE}" >/dev/null 2>&1; then
  ssh-keyscan -H "${BASTION_HOST}" >> "${KNOWN_HOSTS_FILE}" 2>/dev/null || true
fi

SSH_BASE=(-i "${SSH_KEY}" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile="${KNOWN_HOSTS_FILE}")
SSH_OPTS=("${SSH_BASE[@]}" -o ProxyCommand="ssh -i ${SSH_KEY} -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=${KNOWN_HOSTS_FILE} -W %h:%p ${SSH_USER}@${BASTION_HOST}")

ssh_api() {
  local target="${API_POOL_PRIVATE:-${API_POOL_PUBLIC:-}}"
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${target}" "$@"
}

ssh_client() {
  local target="${CLIENT_POOL_PRIVATE:-${CLIENT_POOL_PUBLIC:-}}"
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${target}" "$@"
}

EDGE_SERVICE_SECRET=${EDGE_SERVICE_SECRET:-"E2bEdgeSecret2025!"}

echo "════════════════════════════════════════════════════════════════"
echo "  TESTING CLIENT-PROXY → ORCHESTRATOR CONNECTIVITY"
echo "════════════════════════════════════════════════════════════════"
echo ""

echo "1. Checking orchestrator service status..."
ORCH_STATUS=$(ssh_client "nomad job status orchestrator 2>&1 | grep -E 'Status|Running|Allocations' | head -5" || echo "FAILED")
echo "${ORCH_STATUS}"
echo ""

echo "2. Getting orchestrator node IPs from client-proxy service discovery..."
ORCH_NODES=$(ssh_api "curl -sf -H 'X-API-Key: ${EDGE_SERVICE_SECRET}' 'http://127.0.0.1:3001/v1/service-discovery/nodes/orchestrators' 2>&1 | jq '.'" || echo "[]")
echo "${ORCH_NODES}"
echo ""

echo "3. Getting orchestrator list from client-proxy..."
ORCH_LIST=$(ssh_api "curl -sf -H 'X-API-Key: ${EDGE_SERVICE_SECRET}' 'http://127.0.0.1:3001/v1/service-discovery/orchestrators' 2>&1 | jq '.'" || echo "[]")
echo "${ORCH_LIST}"
echo ""

echo "4. Checking if orchestrator is listening on port 5008..."
ORCH_PORT_CHECK=$(ssh_client "netstat -tlnp 2>/dev/null | grep 5008 || ss -tlnp 2>/dev/null | grep 5008 || echo 'Port 5008 not found'" || echo "FAILED")
echo "${ORCH_PORT_CHECK}"
echo ""

echo "5. Testing TCP connectivity from API pool to orchestrator (port 5008)..."
# Get orchestrator IP from client pool
ORCH_IP=$(ssh_client "hostname -I | awk '{print \$1}'" || echo "")
if [[ -n "${ORCH_IP}" ]]; then
  CONNECTIVITY=$(ssh_api "timeout 2 bash -c '</dev/tcp/${ORCH_IP}/5008' 2>&1 && echo '✓ TCP connection OK' || echo '✗ TCP connection FAILED'" || echo "FAILED")
  echo "   Testing connection to ${ORCH_IP}:5008..."
  echo "   ${CONNECTIVITY}"
else
  echo "   Could not determine orchestrator IP"
fi
echo ""

echo "6. Checking orchestrator health endpoint..."
ORCH_HEALTH=$(ssh_client "curl -sS http://127.0.0.1:5008/health 2>&1" || echo "FAILED")
echo "${ORCH_HEALTH}"
echo ""

echo "7. Checking recent client-proxy logs for orchestrator connection errors..."
CP_ALLOC_ID=$(ssh_api "nomad job allocs client-proxy | tail -n +2 | head -1 | awk '{print \$1}'" || echo "")
if [[ -n "${CP_ALLOC_ID}" ]]; then
  echo "   Recent logs with 'orchestrator' or 'connection' or 'error':"
  ssh_api "nomad alloc logs -stderr ${CP_ALLOC_ID} client-proxy 2>&1 | grep -iE 'orchestrator|connection|error|failed|unreachable' | tail -30" || echo "Failed to get logs"
else
  echo "   Could not find client-proxy allocation"
fi
echo ""

echo "8. Checking orchestrator logs for connection attempts..."
ORCH_ALLOC_ID=$(ssh_client "nomad job allocs orchestrator | tail -n +2 | head -1 | awk '{print \$1}'" || echo "")
if [[ -n "${ORCH_ALLOC_ID}" ]]; then
  echo "   Recent logs with 'connection' or 'client-proxy' or 'grpc':"
  ssh_client "nomad alloc logs -stderr ${ORCH_ALLOC_ID} orchestrator 2>&1 | grep -iE 'connection|client-proxy|grpc|error' | tail -30" || echo "Failed to get logs"
else
  echo "   Could not find orchestrator allocation"
fi
echo ""

echo "════════════════════════════════════════════════════════════════"


