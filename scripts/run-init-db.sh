#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${REPO_ROOT}/deploy.env"

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
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-}
POSTGRES_DB=${POSTGRES_DB:-postgres}
EDGE_SERVICE_SECRET=${EDGE_SERVICE_SECRET:-E2bEdgeSecret2025!}

REQUIRED=(BASTION_HOST API_POOL_PUBLIC POSTGRES_HOST POSTGRES_PASSWORD)
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

quote() {
  printf '%q' "$1"
}

EMAIL_VALUE=${EMAIL:-admin@e2b-oci-poc.local}

printf -v remote_cmd 'cd /opt/e2b && %s %s %s %s %s %s %s %s %s ./db/init-db.sh' \
  "POSTGRES_HOST=$(quote "${POSTGRES_HOST}")" \
  "POSTGRES_PORT=$(quote "${POSTGRES_PORT}")" \
  "POSTGRES_USER=$(quote "${POSTGRES_USER}")" \
  "POSTGRES_PASSWORD=$(quote "${POSTGRES_PASSWORD}")" \
  "POSTGRES_DB=$(quote "${POSTGRES_DB}")" \
  "API_POOL_PRIVATE=$(quote "${API_POOL_PRIVATE}")" \
  "API_POOL_PUBLIC=$(quote "${API_POOL_PUBLIC}")" \
  "EDGE_SERVICE_SECRET=$(quote "${EDGE_SERVICE_SECRET}")" \
  "EMAIL=$(quote "${EMAIL_VALUE}")"

target="${API_POOL_PRIVATE:-${API_POOL_PUBLIC}}"
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${target}" "${remote_cmd}"

