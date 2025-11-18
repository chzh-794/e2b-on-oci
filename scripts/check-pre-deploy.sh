#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/deploy.env"

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "deploy.env not found at ${CONFIG_FILE}. Copy deploy.env.example first." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "${CONFIG_FILE}"
set +a

SSH_USER=${SSH_USER:-ubuntu}
SSH_KEY=${SSH_KEY:-$HOME/.ssh/e2b_id_rsa}
SSH_KEY=${SSH_KEY/#\~/$HOME}
BASTION_HOST=${BASTION_HOST:-}
SERVER_POOL_PUBLIC=${SERVER_POOL_PUBLIC:-}
API_POOL_PUBLIC=${API_POOL_PUBLIC:-}
CLIENT_POOL_PUBLIC=${CLIENT_POOL_PUBLIC:-}
SERVER_POOL_PRIVATE=${SERVER_POOL_PRIVATE:-$SERVER_POOL_PUBLIC}
API_POOL_PRIVATE=${API_POOL_PRIVATE:-$API_POOL_PUBLIC}
CLIENT_POOL_PRIVATE=${CLIENT_POOL_PRIVATE:-$CLIENT_POOL_PUBLIC}
POSTGRES_HOST=${POSTGRES_HOST:-}
POSTGRES_PORT=${POSTGRES_PORT:-5432}
POSTGRES_USER=${POSTGRES_USER:-admin}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-E2bP0cPostgres!2025}
POSTGRES_DB=${POSTGRES_DB:-postgres}

REQUIRED=(BASTION_HOST SERVER_POOL_PUBLIC API_POOL_PUBLIC CLIENT_POOL_PUBLIC POSTGRES_HOST)
for var in "${REQUIRED[@]}"; do
  if [[ -z ${!var:-} ]]; then
    echo "Missing $var in deploy.env" >&2
    exit 1
  fi
done

KNOWN_HOSTS_FILE=${KNOWN_HOSTS_FILE:-$HOME/.ssh/known_hosts}
mkdir -p "$(dirname "${KNOWN_HOSTS_FILE}")"
touch "${KNOWN_HOSTS_FILE}"
for host in "${BASTION_HOST}" "${SERVER_POOL_PRIVATE}" "${API_POOL_PRIVATE}" "${CLIENT_POOL_PRIVATE}"; do
  [[ -z "${host}" ]] && continue
  ssh-keygen -R "${host}" -f "${KNOWN_HOSTS_FILE}" >/dev/null 2>&1 || true
done
if [[ -n "${BASTION_HOST}" ]]; then
  ssh-keyscan -H "${BASTION_HOST}" >> "${KNOWN_HOSTS_FILE}" 2>/dev/null || true
fi

SSH_BASE=(-i "${SSH_KEY}" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile="${KNOWN_HOSTS_FILE}")
SSH_OPTS=("${SSH_BASE[@]}" -o ProxyCommand="ssh -i ${SSH_KEY} -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=${KNOWN_HOSTS_FILE} -W %h:%p ${SSH_USER}@${BASTION_HOST}")

ssh_jump() {
  local host=$1
  shift
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "$@"
}

ssh_jump_quiet() {
  local host=$1
  shift
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "$@" >/dev/null 2>&1
}

API_HOST=${API_POOL_PRIVATE:-$API_POOL_PUBLIC}
if ! ssh_jump_quiet "${API_HOST}" true; then
  API_HOST=${API_POOL_PUBLIC}
fi

CLIENT_HOST=${CLIENT_POOL_PRIVATE:-$CLIENT_POOL_PUBLIC}
if [[ -z "${CLIENT_HOST}" ]]; then
  echo "ERROR: CLIENT_POOL_PRIVATE and CLIENT_POOL_PUBLIC are both unset. Set at least one in deploy.env" >&2
  exit 1
fi
if ! ssh_jump_quiet "${CLIENT_HOST}" true; then
  CLIENT_HOST=${CLIENT_POOL_PUBLIC}
  if [[ -z "${CLIENT_HOST}" ]]; then
    echo "ERROR: Cannot connect to CLIENT_POOL_PRIVATE and CLIENT_POOL_PUBLIC is unset" >&2
    exit 1
  fi
fi

echo "═══════════════════════════════════════════════════════════"
echo "Pre-Deployment Verification"
echo "═══════════════════════════════════════════════════════════"
echo ""

# Track check results
PASSED=0
FAILED=0
WARNINGS=0
FAILED_ITEMS=()
WARNED_ITEMS=()

check_pass() {
  PASSED=$((PASSED + 1))
}

check_fail() {
  FAILED=$((FAILED + 1))
  FAILED_ITEMS+=("$1")
}

check_warn() {
  WARNINGS=$((WARNINGS + 1))
  WARNED_ITEMS+=("$1")
}

echo "1. Checking binaries on API pool..."
if ssh_jump "${API_HOST}" 'test -d /opt/e2b/bin && ls -lh /opt/e2b/bin/ 2>/dev/null || echo "ERROR: /opt/e2b/bin/ not found"'; then
  echo "   ✓ API pool binaries directory exists"
  check_pass
else
  echo "   ✗ ERROR: API pool binaries check failed"
  check_fail "API pool binaries directory /opt/e2b/bin/ does not exist (run deploy-poc.sh Phase 1-2)"
fi
echo ""

echo "2. Checking binaries on Client pool (especially envd)..."
if [[ -z "${CLIENT_HOST}" ]]; then
  echo "   ✗ ERROR: CLIENT_HOST is not set"
  check_fail "CLIENT_HOST is not set (check CLIENT_POOL_PRIVATE/CLIENT_POOL_PUBLIC in deploy.env)"
elif ssh_jump "${CLIENT_HOST}" 'test -d /opt/e2b/bin && ls -lh /opt/e2b/bin/ 2>/dev/null || echo "ERROR: /opt/e2b/bin/ not found"' 2>/dev/null; then
  echo "   ✓ Client pool binaries directory exists"
  check_pass
else
  echo "   ✗ ERROR: Client pool binaries check failed"
  check_fail "Client pool binaries directory /opt/e2b/bin/ does not exist (run deploy-poc.sh Phase 1-2) or SSH connection failed"
fi
echo ""

echo "3. Verifying envd exists on Client pool..."
ENVD_CHECK=$(ssh_jump "${CLIENT_HOST}" 'test -f /opt/e2b/bin/envd && echo "FOUND" || echo "NOT_FOUND"' 2>/dev/null || echo "NOT_FOUND")
if [[ "${ENVD_CHECK}" == "FOUND" ]]; then
  echo "   ✓ envd binary found"
  check_pass
else
  echo "   ✗ ERROR: envd binary not found at /opt/e2b/bin/envd"
  check_fail "envd binary does not exist at /opt/e2b/bin/envd (required for sandbox execution)"
fi
echo ""

echo "4. Checking Nomad client config (no_cgroups)..."
NO_CGROUPS_CHECK=$(ssh_jump "${CLIENT_HOST}" 'grep -q "no_cgroups = true" /opt/nomad/config/client.hcl 2>/dev/null && echo "FOUND" || echo "NOT_FOUND"' 2>/dev/null || echo "NOT_FOUND")
if [[ "${NO_CGROUPS_CHECK}" == "FOUND" ]]; then
  echo "   ✓ no_cgroups = true configured"
  check_pass
else
  echo "   ✗ ERROR: no_cgroups not found in Nomad config"
  check_fail "Nomad client.hcl missing 'no_cgroups = true' in raw_exec plugin config (required for Firecracker mounts)"
fi
echo ""

echo "5. Checking configuration files..."
API_ENV_COUNT=$(ssh_jump "${API_HOST}" 'ls -1 /opt/e2b/*.env 2>/dev/null | wc -l' 2>/dev/null || echo "0")
CLIENT_ENV_COUNT=$(ssh_jump "${CLIENT_HOST}" 'ls -1 /opt/e2b/*.env 2>/dev/null | wc -l' 2>/dev/null || echo "0")
echo "   API pool: ${API_ENV_COUNT} env files"
echo "   Client pool: ${CLIENT_ENV_COUNT} env files"
if [[ "${API_ENV_COUNT}" -ge 2 ]] && [[ "${CLIENT_ENV_COUNT}" -ge 2 ]]; then
  echo "   ✓ Configuration files present"
  check_pass
else
  echo "   ✗ WARNING: Expected at least 2 env files per pool"
  check_warn "Configuration files (expected 2+ per pool, found API:${API_ENV_COUNT} Client:${CLIENT_ENV_COUNT})"
fi
echo ""

echo "6. Checking Nomad client service status..."
NOMAD_STATUS=$(ssh_jump "${CLIENT_HOST}" 'systemctl is-active nomad.service >/dev/null 2>&1 && echo "ACTIVE" || echo "INACTIVE"' 2>/dev/null || echo "INACTIVE")
if [[ "${NOMAD_STATUS}" == "ACTIVE" ]]; then
  echo "   ✓ Nomad client service is active"
  check_pass
else
  echo "   ✗ ERROR: Nomad client service is not active"
  check_fail "Nomad client service is not running (check: systemctl status nomad)"
fi
echo ""

echo "═══════════════════════════════════════════════════════════"
echo "Infrastructure Health Checks"
echo "═══════════════════════════════════════════════════════════"
echo ""

echo "== Nomad server health =="
SERVER_HOST=${SERVER_POOL_PRIVATE:-$SERVER_POOL_PUBLIC}
if [[ -z "${SERVER_HOST}" ]]; then
  echo "SERVER_POOL_PRIVATE or SERVER_POOL_PUBLIC must be set for Nomad HTTP checks." >&2
  exit 1
fi
NOMAD_HTTP="http://${SERVER_HOST}:4646"
ssh_jump "${API_HOST}" "curl -sf ${NOMAD_HTTP}/v1/status/leader || echo 'Leader check failed'"
ssh_jump "${API_HOST}" "curl -sf ${NOMAD_HTTP}/v1/status/peers || echo 'Peers check failed'"
echo ""

echo "== Validating Nomad node class configuration (config files) ==="
# Check config files only (Nomad API validation happens in post-deploy)
API_CONFIG_CLASS=$(ssh_jump "${API_HOST}" 'grep "node_class" /opt/nomad/config/client.hcl 2>/dev/null | sed -n "s/.*node_class = \"\([^\"]*\)\".*/\1/p" | head -1' || echo "")
CLIENT_CONFIG_CLASS=$(ssh_jump "${CLIENT_HOST}" 'grep "node_class" /opt/nomad/config/client.hcl 2>/dev/null | sed -n "s/.*node_class = \"\([^\"]*\)\".*/\1/p" | head -1' || echo "")

if [[ "${API_CONFIG_CLASS}" == "api" ]]; then
  echo "   ✓ API pool config has node_class = 'api'"
  check_pass
elif [[ -n "${API_CONFIG_CLASS}" ]]; then
  echo "   ✗ ERROR: API pool config has node_class = '${API_CONFIG_CLASS}' (expected 'api')"
  check_fail "API pool node_class in config is '${API_CONFIG_CLASS}' but must be 'api' (check /opt/nomad/config/client.hcl)"
else
  echo "   ✗ ERROR: API pool config missing node_class"
  check_fail "API pool config missing node_class (check /opt/nomad/config/client.hcl meta block)"
fi

if [[ "${CLIENT_CONFIG_CLASS}" == "client" ]]; then
  echo "   ✓ Client pool config has node_class = 'client'"
  check_pass
elif [[ -n "${CLIENT_CONFIG_CLASS}" ]]; then
  echo "   ✗ ERROR: Client pool config has node_class = '${CLIENT_CONFIG_CLASS}' (expected 'client')"
  check_fail "Client pool node_class in config is '${CLIENT_CONFIG_CLASS}' but must be 'client' (check /opt/nomad/config/client.hcl)"
else
  echo "   ✗ ERROR: Client pool config missing node_class"
  check_fail "Client pool config missing node_class (check /opt/nomad/config/client.hcl meta block)"
fi

echo "== PostgreSQL connectivity from API node =="
if ssh_jump "${API_HOST}" "PGPASSWORD='${POSTGRES_PASSWORD}' psql 'postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}?sslmode=require' -c 'select 1;' >/dev/null 2>&1"; then
  echo "   ✓ PostgreSQL connection successful"
  check_pass
else
  echo "   ✗ ERROR: PostgreSQL connection failed"
  check_fail "PostgreSQL connection failed (check credentials and network connectivity)"
fi

echo ""
echo "== Database initialization status =="
SQL_CONN="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}?sslmode=require"

# Check if team exists
TEAM_COUNT=$(ssh_jump "${API_HOST}" "PGPASSWORD='${POSTGRES_PASSWORD}' psql '${SQL_CONN}' -At -c 'SELECT COUNT(*) FROM teams;' 2>/dev/null" | tr -d '\r' || echo "0")
if [[ "${TEAM_COUNT}" -gt 0 ]]; then
  echo "   ✓ Teams exist (${TEAM_COUNT})"
  check_pass
else
  echo "   ✗ ERROR: No teams found in database"
  check_fail "Database not initialized - no teams found (run deploy-poc.sh Phase 1d or ./scripts/run-init-db.sh)"
fi

# Check if API key exists
API_KEY_COUNT=$(ssh_jump "${API_HOST}" "PGPASSWORD='${POSTGRES_PASSWORD}' psql '${SQL_CONN}' -At -c 'SELECT COUNT(*) FROM team_api_keys;' 2>/dev/null" | tr -d '\r' || echo "0")
if [[ "${API_KEY_COUNT}" -gt 0 ]]; then
  echo "   ✓ API keys exist (${API_KEY_COUNT})"
  check_pass
else
  echo "   ✗ ERROR: No API keys found in database"
  check_fail "Database not initialized - no API keys found (run deploy-poc.sh Phase 1d or ./scripts/run-init-db.sh)"
fi

# Check if admin token exists
TOKEN_COUNT=$(ssh_jump "${API_HOST}" "PGPASSWORD='${POSTGRES_PASSWORD}' psql '${SQL_CONN}' -At -c 'SELECT COUNT(*) FROM access_tokens;' 2>/dev/null" | tr -d '\r' || echo "0")
if [[ "${TOKEN_COUNT}" -gt 0 ]]; then
  echo "   ✓ Admin tokens exist (${TOKEN_COUNT})"
  check_pass
else
  echo "   ✗ ERROR: No admin tokens found in database"
  check_fail "Database not initialized - no admin tokens found (run deploy-poc.sh Phase 1d or ./scripts/run-init-db.sh)"
fi

# Check if team has cluster_id set (critical for sandbox execution)
TEAM_CLUSTER_CHECK=$(ssh_jump "${API_HOST}" "PGPASSWORD='${POSTGRES_PASSWORD}' psql '${SQL_CONN}' -At -c 'SELECT COUNT(*) FROM teams WHERE cluster_id IS NOT NULL;' 2>/dev/null" | tr -d '\r' || echo "0")
if [[ "${TEAM_CLUSTER_CHECK}" -gt 0 ]]; then
  echo "   ✓ Teams have cluster_id configured (${TEAM_CLUSTER_CHECK})"
  check_pass
else
  echo "   ✗ ERROR: No teams have cluster_id set"
  check_fail "Teams missing cluster_id - sandbox execution will fail (run deploy-poc.sh Phase 1d or ./scripts/run-init-db.sh)"
fi

# Check if cluster entry exists
CLUSTER_COUNT=$(ssh_jump "${API_HOST}" "PGPASSWORD='${POSTGRES_PASSWORD}' psql '${SQL_CONN}' -At -c 'SELECT COUNT(*) FROM clusters;' 2>/dev/null" | tr -d '\r' || echo "0")
if [[ "${CLUSTER_COUNT}" -gt 0 ]]; then
  echo "   ✓ Clusters configured (${CLUSTER_COUNT})"
  check_pass
  
  # Verify cluster endpoint matches expected client-proxy endpoint
  EXPECTED_ENDPOINT="${API_POOL_PRIVATE:-${API_POOL_PUBLIC}}:3001"
  CLUSTER_ENDPOINT=$(ssh_jump "${API_HOST}" "PGPASSWORD='${POSTGRES_PASSWORD}' psql '${SQL_CONN}' -At -c 'SELECT endpoint FROM clusters LIMIT 1;' 2>/dev/null" | tr -d '\r' || echo "")
  if [[ -n "${CLUSTER_ENDPOINT}" ]]; then
    if [[ "${CLUSTER_ENDPOINT}" == "${EXPECTED_ENDPOINT}" ]]; then
      echo "   ✓ Cluster endpoint matches expected (${CLUSTER_ENDPOINT})"
      check_pass
    else
      echo "   ⚠ WARNING: Cluster endpoint is '${CLUSTER_ENDPOINT}' but expected '${EXPECTED_ENDPOINT}'"
      check_warn "Cluster endpoint mismatch (current: ${CLUSTER_ENDPOINT}, expected: ${EXPECTED_ENDPOINT})"
    fi
  fi
else
  echo "   ✗ ERROR: No clusters found in database"
  check_fail "No clusters configured - sandbox execution will fail (run deploy-poc.sh Phase 1d or ./scripts/run-init-db.sh)"
fi

echo "== Client pool readiness =="
ssh_jump "${CLIENT_HOST}" 'if sudo -n true 2>/dev/null; then sudo -n systemctl is-active docker && echo "docker.service active"; else systemctl is-active docker && echo "docker.service active"; fi'
ssh_jump "${CLIENT_HOST}" 'ls -ld /var/e2b/templates'
ssh_jump "${CLIENT_HOST}" 'ls -ld /fc-kernels /fc-versions || true'

echo "== Consul cluster membership =="
echo "API Pool Consul status:"
ssh_jump "${API_HOST}" '/usr/local/bin/consul members 2>/dev/null | grep -E "(server|client)" || echo "Consul not connected"'
echo "Client Pool Consul status:"
ssh_jump "${CLIENT_HOST}" '/usr/local/bin/consul members 2>/dev/null | grep -E "(server|client)" || echo "Consul not connected"'

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "Pre-Deployment Check Summary"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "  ✓ Passed:  ${PASSED}"
if [[ ${WARNINGS} -gt 0 ]]; then
  echo "  ⚠ Warnings: ${WARNINGS}"
  echo ""
  echo "  Warning items:"
  for item in "${WARNED_ITEMS[@]}"; do
    echo "    - ${item}"
  done
fi
if [[ ${FAILED} -gt 0 ]]; then
  echo "  ✗ Failed:  ${FAILED}"
  echo ""
  echo "  Failed items:"
  for item in "${FAILED_ITEMS[@]}"; do
    echo "    - ${item}"
  done
fi
echo ""

if [[ ${FAILED} -eq 0 ]]; then
  echo "✅ All pre-deployment checks passed!"
  echo ""
  echo "You can proceed with: ./deploy-services.sh"
  echo "After deploying services, run: ./scripts/check-post-deploy.sh"
  exit 0
else
  echo "❌ Some pre-deployment checks failed. Please fix the issues above before proceeding."
  echo ""
  echo "After fixing issues, you can proceed with: ./deploy-services.sh"
  echo "After deploying services, run: ./scripts/check-post-deploy.sh"
  exit 1
fi
