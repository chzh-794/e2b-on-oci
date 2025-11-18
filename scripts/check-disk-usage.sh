#!/bin/bash
# Check what's taking up disk space on the client pool

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source deploy.env
CONFIG_FILE="${REPO_ROOT}/deploy.env"

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "deploy.env not found at ${CONFIG_FILE}" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "${CONFIG_FILE}"
set +a

SSH_USER=${SSH_USER:-ubuntu}
SSH_KEY=${SSH_KEY:-$HOME/.ssh/e2b_id_rsa}
SSH_KEY=${SSH_KEY/#\~/$HOME}
BASTION_HOST="${BASTION_HOST:-}"
CLIENT_POOL_PRIVATE=${CLIENT_POOL_PRIVATE:-}
CLIENT_POOL_PUBLIC=${CLIENT_POOL_PUBLIC:-}

REQUIRED=(BASTION_HOST CLIENT_POOL_PRIVATE CLIENT_POOL_PUBLIC)
for var in "${REQUIRED[@]}"; do
  if [[ -z ${!var:-} ]]; then
    echo "Missing $var (ensure deploy.env is populated)." >&2
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

CLIENT_POOL_TARGET="${CLIENT_POOL_PRIVATE:-${CLIENT_POOL_PUBLIC:-}}"

ssh_jump() {
  local target="$1"
  shift
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${target}" "$@"
}

echo "╔════════════════════════════════════════════════════════════╗"
echo "║       Disk Usage Analysis                                 ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# 1. Overall disk usage
echo "1. Overall disk usage:"
echo ""
ssh_jump "${CLIENT_POOL_TARGET}" "df -h /"
echo ""

# 2. Check /var/e2b directory
echo "2. /var/e2b directory usage:"
echo ""
ssh_jump "${CLIENT_POOL_TARGET}" "sudo du -sh /var/e2b/* 2>/dev/null | sort -hr | head -20" || echo "  Could not check /var/e2b"
echo ""

# 3. Check templates directory
echo "3. Templates directory:"
echo ""
TEMPLATE_COUNT=$(ssh_jump "${CLIENT_POOL_TARGET}" "sudo ls -d /var/e2b/templates/* 2>/dev/null | wc -l" || echo "0")
echo "  Template directories: ${TEMPLATE_COUNT}"
if [[ "${TEMPLATE_COUNT}" -gt 0 ]]; then
  echo ""
  echo "  Template sizes:"
  ssh_jump "${CLIENT_POOL_TARGET}" "sudo du -sh /var/e2b/templates/* 2>/dev/null | sort -hr"
fi
echo ""

# 4. Check Docker images
echo "4. Docker images:"
echo ""
DOCKER_SIZE=$(ssh_jump "${CLIENT_POOL_TARGET}" "sudo docker system df 2>/dev/null" || echo "  Could not check Docker")
echo "${DOCKER_SIZE}"
echo ""

# 5. Check Docker images by template
echo "5. Docker images tagged with template IDs:"
echo ""
ssh_jump "${CLIENT_POOL_TARGET}" "sudo docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.Size}}' | grep -E '^[a-z0-9]+\s+[a-z0-9-]+\s+' | head -20" || echo "  No template images found"
echo ""

# 6. Check for large files in /var/e2b
echo "6. Largest files in /var/e2b:"
echo ""
ssh_jump "${CLIENT_POOL_TARGET}" "sudo find /var/e2b -type f -size +100M -exec ls -lh {} \; 2>/dev/null | awk '{print \$5, \$9}' | sort -hr | head -10" || echo "  Could not find large files"
echo ""

# 7. Check /tmp for large files
echo "7. Large files in /tmp:"
echo ""
ssh_jump "${CLIENT_POOL_TARGET}" "sudo find /tmp -type f -size +100M -exec ls -lh {} \; 2>/dev/null | awk '{print \$5, \$9}' | sort -hr | head -10" || echo "  No large files in /tmp"
echo ""

# 8. Check for orphaned rootfs files
echo "8. Rootfs files in /var/e2b/templates:"
echo ""
ssh_jump "${CLIENT_POOL_TARGET}" "sudo find /var/e2b/templates -name '*.ext4*' -type f -exec ls -lh {} \; 2>/dev/null | awk '{print \$5, \$9}' | sort -hr" || echo "  No rootfs files found"
echo ""

echo "═══════════════════════════════════════════════════════════"
echo "Analysis complete."
echo "═══════════════════════════════════════════════════════════"

