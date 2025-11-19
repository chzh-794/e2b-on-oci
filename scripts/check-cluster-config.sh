#!/bin/bash
# Check cluster endpoint and auth configuration in database

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
BASTION=${BASTION_HOST}

if [[ -n "${BASTION}" ]]; then
  SSH_OPTS=(-o "StrictHostKeyChecking=no" -o "ProxyJump=${SSH_USER}@${BASTION}" -i "${SSH_KEY}")
else
  SSH_OPTS=(-o "StrictHostKeyChecking=no" -i "${SSH_KEY}")
fi

ssh_api() {
  ssh "${SSH_OPTS[@]}" ${SSH_USER}@${API_TARGET} "$@"
}

POSTGRES_USER=${POSTGRES_USER:-admin}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-E2bP0cPostgres!2025}
POSTGRES_DB=${POSTGRES_DB:-postgres}
POSTGRES_PORT=${POSTGRES_PORT:-5432}

EDGE_SERVICE_SECRET=${EDGE_SERVICE_SECRET:-"E2bEdgeSecret2025!"}
API_POOL_IP=${API_POOL_PRIVATE:-${API_POOL_PUBLIC:-"127.0.0.1"}}
EXPECTED_ENDPOINT="${API_POOL_IP}:3001"

echo "════════════════════════════════════════════════════════════════"
echo "  CLUSTER CONFIGURATION CHECK"
echo "════════════════════════════════════════════════════════════════"
echo ""

echo "Expected Configuration:"
echo "  Endpoint: ${EXPECTED_ENDPOINT}"
echo "  Token: ${EDGE_SERVICE_SECRET}"
echo "  Endpoint TLS: false"
echo ""

echo "Database Configuration:"
ssh_api "PGPASSWORD='${POSTGRES_PASSWORD}' psql -h ${POSTGRES_HOST} -p ${POSTGRES_PORT} -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c \"
SELECT 
    id,
    endpoint,
    endpoint_tls,
    CASE 
        WHEN token = '${EDGE_SERVICE_SECRET}' THEN 'MATCH ✓'
        ELSE 'MISMATCH ✗ (token: ' || LEFT(token, 20) || '...)'
    END as token_match,
    CASE 
        WHEN endpoint = '${EXPECTED_ENDPOINT}' THEN 'MATCH ✓'
        ELSE 'MISMATCH ✗'
    END as endpoint_match
FROM clusters;
\"" 2>&1 || echo "Failed to query database"

echo ""
echo "Team-Cluster Association:"
ssh_api "PGPASSWORD='${POSTGRES_PASSWORD}' psql -h ${POSTGRES_HOST} -p ${POSTGRES_PORT} -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c \"
SELECT 
    t.id as team_id,
    t.name as team_name,
    t.cluster_id,
    c.endpoint as cluster_endpoint
FROM teams t
LEFT JOIN clusters c ON t.cluster_id = c.id;
\"" 2>&1 || echo "Failed to query database"

echo ""
echo "════════════════════════════════════════════════════════════════"
