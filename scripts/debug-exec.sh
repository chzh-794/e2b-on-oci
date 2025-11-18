#!/bin/bash
# Debug script for sandbox execution failures
# Usage: ./scripts/debug-exec.sh <sandbox-id>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${REPO_ROOT}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <sandbox-id>"
  exit 1
fi

SANDBOX_ID="$1"

# Source environment
if [[ ! -f "${REPO_ROOT}/deploy.env" ]]; then
  echo -e "${RED}Error: deploy.env not found${NC}" >&2
  exit 1
fi

source "${REPO_ROOT}/deploy.env"

if [[ ! -f "${REPO_ROOT}/api-creds.env" ]]; then
  echo -e "${YELLOW}Warning: api-creds.env not found${NC}" >&2
fi

source "${REPO_ROOT}/api-creds.env" 2>/dev/null || true

REQUIRED=(BASTION_HOST API_POOL_PRIVATE TEAM_API_KEY ADMIN_API_TOKEN)
for var in "${REQUIRED[@]}"; do
  if [[ -z ${!var:-} ]]; then
    echo -e "${RED}Error: Missing $var${NC}" >&2
    exit 1
  fi
done

SSH_BASE=(-i "${SSH_KEY}" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile="${HOME}/.ssh/known_hosts")
SSH_OPTS=("${SSH_BASE[@]}" -o ProxyCommand="ssh -i ${SSH_KEY} -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=${HOME}/.ssh/known_hosts -W %h:%p ${SSH_USER}@${BASTION_HOST}")

ssh_api() {
  local target="${API_POOL_PRIVATE:-${API_POOL_PUBLIC:-}}"
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${target}" "$@"
}

ssh_client() {
  local target="${CLIENT_POOL_PRIVATE:-${CLIENT_POOL_PUBLIC:-}}"
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${target}" "$@"
}

api_get() {
  local endpoint="$1"
  ssh_api "curl -sf -H 'X-API-Key: ${TEAM_API_KEY}' -H 'Authorization: Bearer ${ADMIN_API_TOKEN}' 'http://127.0.0.1:50001${endpoint}'"
}

api_post() {
  local endpoint="$1"
  local body="$2"
  ssh_api "curl -sf -X POST -H 'Content-Type: application/json' -H 'X-API-Key: ${TEAM_API_KEY}' -H 'Authorization: Bearer ${ADMIN_API_TOKEN}' -d '${body}' 'http://127.0.0.1:50001${endpoint}'"
}

echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Sandbox Execution Debug: ${SANDBOX_ID}${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo ""

echo "1. Checking sandbox status via API..."
SANDBOX_INFO=$(api_get "/v1/sandboxes/${SANDBOX_ID}" 2>/dev/null || echo "{}")
if echo "${SANDBOX_INFO}" | jq -e '.sandboxID' >/dev/null 2>&1; then
  echo -e "${GREEN}✓ Sandbox found in API${NC}"
  echo "${SANDBOX_INFO}" | jq '{sandboxID, clientID, templateID, state}'
  CLIENT_ID=$(echo "${SANDBOX_INFO}" | jq -r '.clientID // empty')
else
  echo -e "${RED}✗ Sandbox not found in API${NC}"
  echo "${SANDBOX_INFO}"
fi
echo ""

echo "2. Checking if sandbox is in client-proxy catalog..."
CATALOG_CHECK=$(ssh_api "curl -sf -X POST -H 'Content-Type: application/json' -H 'X-API-Key: ${EDGE_SERVICE_SECRET:-E2bEdgeSecret2025!}' -d '{\"sandboxId\":\"${SANDBOX_ID}\"}' 'http://127.0.0.1:3001/v1/sandboxes/catalog' 2>&1" || echo "{}")
if echo "${CATALOG_CHECK}" | jq -e '.sandboxId' >/dev/null 2>&1; then
  echo -e "${GREEN}✓ Sandbox found in catalog${NC}"
  echo "${CATALOG_CHECK}" | jq '.'
else
  echo -e "${RED}✗ Sandbox NOT in catalog${NC}"
  echo "${CATALOG_CHECK}"
fi
echo ""

echo "3. Checking orchestrator node status..."
ORCH_NODES=$(ssh_api "curl -sf -H 'X-API-Key: ${EDGE_SERVICE_SECRET:-E2bEdgeSecret2025!}' 'http://127.0.0.1:3001/v1/service-discovery/nodes/orchestrators' | jq '.'" || echo "[]")
ORCH_COUNT=$(echo "${ORCH_NODES}" | jq 'length')
if [[ "${ORCH_COUNT}" -gt 0 ]]; then
  echo -e "${GREEN}✓ Found ${ORCH_COUNT} orchestrator node(s)${NC}"
  echo "${ORCH_NODES}" | jq '.[] | {nodeID, serviceStatus, serviceHost}'
else
  echo -e "${RED}✗ No orchestrator nodes found${NC}"
fi
echo ""

if [[ -n "${CLIENT_ID:-}" ]]; then
  echo "4. Checking if orchestrator node matches sandbox clientID..."
  ORCH_NODE_ID=$(echo "${ORCH_NODES}" | jq -r '.[0].nodeID // empty')
  if [[ "${CLIENT_ID}" == "${ORCH_NODE_ID}" ]]; then
    echo -e "${GREEN}✓ Node IDs match: ${CLIENT_ID}${NC}"
  else
    echo -e "${YELLOW}⚠ Node ID mismatch:${NC}"
    echo "  Sandbox clientID: ${CLIENT_ID}"
    echo "  Orchestrator nodeID: ${ORCH_NODE_ID}"
  fi
  echo ""
fi

echo "5. Checking orchestrator process on client pool..."
ORCH_PROCESS=$(ssh_client "sudo ps aux | grep -E '[f]irecracker.*${SANDBOX_ID}|[o]rchestrator.*${SANDBOX_ID}' || echo 'No process found'" || echo "Check failed")
echo "${ORCH_PROCESS}"
echo ""

echo "6. Checking orchestrator logs for sandbox..."
ALLOC_ID=$(ssh_client "nomad job allocs orchestrator | tail -n +2 | head -1 | awk '{print \$1}'" || echo "")
if [[ -n "${ALLOC_ID}" ]]; then
  echo "Recent orchestrator logs:"
  ssh_client "nomad alloc logs -stderr ${ALLOC_ID} orchestrator 2>&1 | grep -iE '${SANDBOX_ID}|exec|error' | tail -20" || echo "Failed to get logs"
else
  echo -e "${RED}✗ Could not find orchestrator allocation${NC}"
fi
echo ""

echo "7. Checking client-proxy logs..."
CP_ALLOC_ID=$(ssh_api "nomad job allocs client-proxy | tail -n +2 | head -1 | awk '{print \$1}'" || echo "")
if [[ -n "${CP_ALLOC_ID}" ]]; then
  echo "Recent client-proxy logs:"
  ssh_api "nomad alloc logs -stderr ${CP_ALLOC_ID} client-proxy 2>&1 | grep -iE '${SANDBOX_ID}|exec|error|orchestrator' | tail -20" || echo "Failed to get logs"
else
  echo -e "${RED}✗ Could not find client-proxy allocation${NC}"
fi
echo ""

echo "8. Testing direct exec via edge API..."
EXEC_TEST=$(ssh_api "curl -sf -X POST -H 'Content-Type: application/json' -H 'X-API-Key: ${EDGE_SERVICE_SECRET:-E2bEdgeSecret2025!}' -d '{\"command\":\"echo\",\"args\":[\"test\"]}' 'http://127.0.0.1:3001/v1/sandboxes/${SANDBOX_ID}/exec' 2>&1" || echo "{}")
if echo "${EXEC_TEST}" | jq -e '.stdout' >/dev/null 2>&1; then
  echo -e "${GREEN}✓ Exec works via edge API${NC}"
  echo "${EXEC_TEST}" | jq '.'
else
  echo -e "${RED}✗ Exec failed via edge API${NC}"
  echo "${EXEC_TEST}"
fi
echo ""

echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Debug complete${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"

