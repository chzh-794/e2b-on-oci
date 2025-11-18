#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${REPO_ROOT}/deploy.env"
OUTPUT_FILE="${REPO_ROOT}/api-creds.env"

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
API_POOL_PUBLIC=${API_POOL_PUBLIC:-}
API_POOL_PRIVATE=${API_POOL_PRIVATE:-}
POSTGRES_HOST=${POSTGRES_HOST:-}
POSTGRES_PORT=${POSTGRES_PORT:-5432}
POSTGRES_USER=${POSTGRES_USER:-admin}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-E2bP0cPostgres!2025}
POSTGRES_DB=${POSTGRES_DB:-postgres}

REQUIRED=(BASTION_HOST API_POOL_PUBLIC POSTGRES_HOST POSTGRES_USER POSTGRES_PASSWORD)
for var in "${REQUIRED[@]}"; do
  if [[ -z ${!var:-} ]]; then
    echo "Missing $var in deploy.env" >&2
    exit 1
  fi
done

KNOWN_HOSTS_FILE=${KNOWN_HOSTS_FILE:-$HOME/.ssh/known_hosts}
mkdir -p "$(dirname "${KNOWN_HOSTS_FILE}")"
touch "${KNOWN_HOSTS_FILE}"
if ! ssh-keygen -F "${BASTION_HOST}" -f "${KNOWN_HOSTS_FILE}" >/dev/null 2>&1; then
  ssh-keyscan -H "${BASTION_HOST}" >> "${KNOWN_HOSTS_FILE}" 2>/dev/null || true
fi

SSH_BASE=(-i "${SSH_KEY}" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile="${KNOWN_HOSTS_FILE}")
SSH_OPTS=("${SSH_BASE[@]}" -o ProxyCommand="ssh -i ${SSH_KEY} -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=${KNOWN_HOSTS_FILE} -W %h:%p ${SSH_USER}@${BASTION_HOST}")

SQL_CONN="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}?sslmode=require"

run_sql() {
  local query=$1
  local target="${API_POOL_PRIVATE:-${API_POOL_PUBLIC}}"
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${target}" \
    "PGPASSWORD='${POSTGRES_PASSWORD}' psql '${SQL_CONN}' -At -c \"${query}\"" \
    | tr -d '\r'
}

TEAM_API_KEY=$(run_sql "SELECT api_key FROM team_api_keys ORDER BY created_at DESC LIMIT 1;")
ADMIN_API_TOKEN=$(run_sql "SELECT access_token FROM access_tokens ORDER BY created_at DESC LIMIT 1;")

if [[ -z "${TEAM_API_KEY}" || -z "${ADMIN_API_TOKEN}" ]]; then
  echo "Failed to retrieve credentials from PostgreSQL. Ensure init-db.sh has been applied." >&2
  exit 1
fi

cat > "${OUTPUT_FILE}" <<EOF
# Exported by scripts/export-api-creds.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
TEAM_API_KEY=${TEAM_API_KEY}
ADMIN_API_TOKEN=${ADMIN_API_TOKEN}
EOF

echo "Wrote credentials to ${OUTPUT_FILE}."
echo "Source it with:  set -a; source ${OUTPUT_FILE}; set +a"

