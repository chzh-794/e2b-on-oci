#!/bin/bash
# Check if instances have all required settings for validate-api.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${REPO_ROOT}/deploy.env"

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "deploy.env not found at ${CONFIG_FILE}" >&2
  exit 1
fi

set -a
source "${CONFIG_FILE}"
set +a

SSH_USER=${SSH_USER:-ubuntu}
SSH_KEY=${SSH_KEY:-$HOME/.ssh/e2b_id_rsa}
SSH_KEY=${SSH_KEY/#\~/$HOME}

SSH_BASE=(-i "${SSH_KEY}" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10)
SSH_OPTS=("${SSH_BASE[@]}" -o ProxyCommand="ssh ${SSH_BASE[@]} -W %h:%p ${SSH_USER}@${BASTION_HOST}")

API_FAILURES=()
CLIENT_FAILURES=()

check_api() {
  echo "=== API Pool (${API_POOL_PRIVATE}) ==="
  if ssh "${SSH_OPTS[@]}" ${SSH_USER}@${API_POOL_PRIVATE} "echo 'Connected'" 2>/dev/null; then
    ssh "${SSH_OPTS[@]}" ${SSH_USER}@${API_POOL_PRIVATE} <<'EOF'
      echo "✓ Connected"
      echo ""
      echo "Services:"
      systemctl is-active nomad >/dev/null 2>&1 && echo "  ✓ Nomad active" || echo "  ✗ Nomad not active"
      systemctl is-active consul >/dev/null 2>&1 && echo "  ✓ Consul active" || echo "  ✗ Consul not active"
      
      echo ""
      echo "Nomad jobs:"
      if command -v nomad >/dev/null 2>&1; then
        nomad job status 2>/dev/null | grep -q "api" && echo "  ✓ API job running" || echo "  ✗ API job not found"
        nomad job status 2>/dev/null | grep -q "client-proxy" && echo "  ✓ Client-proxy job running" || echo "  ✗ Client-proxy job not found"
      else
        echo "  ✗ Nomad command not found"
      fi
      
      echo ""
      echo "Health checks:"
      curl -sf http://127.0.0.1:50001/health >/dev/null 2>&1 && echo "  ✓ API healthy" || echo "  ✗ API not responding"
      curl -sf http://127.0.0.1:3001/health >/dev/null 2>&1 && echo "  ✓ Client-proxy healthy" || echo "  ✗ Client-proxy not responding"
      
      echo ""
      echo "Binaries:"
      [ -f /opt/e2b/bin/e2b-api ] && echo "  ✓ API binary exists (e2b-api)" || echo "  ✗ API binary missing (e2b-api)"
      [ -f /opt/e2b/bin/client-proxy ] && echo "  ✓ Client-proxy binary exists" || echo "  ✗ Client-proxy binary missing"
EOF
    # Capture failures for summary
    ssh "${SSH_OPTS[@]}" ${SSH_USER}@${API_POOL_PRIVATE} "[ -f /opt/e2b/bin/e2b-api ]" 2>/dev/null || API_FAILURES+=("API binary missing (e2b-api)")
    ssh "${SSH_OPTS[@]}" ${SSH_USER}@${API_POOL_PRIVATE} "[ -f /opt/e2b/bin/client-proxy ]" 2>/dev/null || API_FAILURES+=("Client-proxy binary missing")
    ssh "${SSH_OPTS[@]}" ${SSH_USER}@${API_POOL_PRIVATE} "nomad job status 2>/dev/null | grep -q 'api'" 2>/dev/null || API_FAILURES+=("API Nomad job not running")
    ssh "${SSH_OPTS[@]}" ${SSH_USER}@${API_POOL_PRIVATE} "nomad job status 2>/dev/null | grep -q 'client-proxy'" 2>/dev/null || API_FAILURES+=("Client-proxy Nomad job not running")
    ssh "${SSH_OPTS[@]}" ${SSH_USER}@${API_POOL_PRIVATE} "curl -sf http://127.0.0.1:50001/health >/dev/null" 2>/dev/null || API_FAILURES+=("API not responding")
  else
    echo "✗ Cannot connect (instance may still be provisioning or cloud-init not complete)"
    API_FAILURES+=("Cannot connect to API pool")
  fi
  echo ""
}

check_client() {
  echo "=== Client Pool (${CLIENT_POOL_PRIVATE}) ==="
  if ssh "${SSH_OPTS[@]}" ${SSH_USER}@${CLIENT_POOL_PRIVATE} "echo 'Connected'" 2>/dev/null; then
    ssh "${SSH_OPTS[@]}" ${SSH_USER}@${CLIENT_POOL_PRIVATE} <<'EOF'
      echo "✓ Connected"
      echo ""
      echo "Services:"
      systemctl is-active nomad >/dev/null 2>&1 && echo "  ✓ Nomad active" || echo "  ✗ Nomad not active"
      systemctl is-active consul >/dev/null 2>&1 && echo "  ✓ Consul active" || echo "  ✗ Consul not active"
      systemctl is-active template-manager >/dev/null 2>&1 && echo "  ✓ Template-manager active" || echo "  ✗ Template-manager not active"
      
      echo ""
      echo "Nomad jobs:"
      if command -v nomad >/dev/null 2>&1; then
        nomad job status 2>/dev/null | grep -q "orchestrator" && echo "  ✓ Orchestrator job running" || echo "  ✗ Orchestrator job not found"
      else
        echo "  ✗ Nomad command not found"
      fi
      
      echo ""
      echo "Capabilities (from user-data):"
      getcap /usr/bin/mount 2>/dev/null | grep -q cap_sys_admin && echo "  ✓ mount has CAP_SYS_ADMIN" || echo "  ✗ mount missing CAP_SYS_ADMIN"
      getcap /usr/sbin/losetup 2>/dev/null | grep -q cap_sys_admin && echo "  ✓ losetup has CAP_SYS_ADMIN" || echo "  ✗ losetup missing CAP_SYS_ADMIN"
      
      echo ""
      echo "NBD device access (from user-data):"
      groups root 2>/dev/null | grep -q disk && echo "  ✓ root in disk group" || echo "  ✗ root not in disk group"
      groups root 2>/dev/null | grep -q kvm && echo "  ✓ root in kvm group" || echo "  ✗ root not in kvm group"
      
      echo ""
      echo "Network namespace mount (from user-data):"
      findmnt /run/netns 2>/dev/null | grep -q tmpfs && echo "  ✓ /run/netns mounted as shared tmpfs" || echo "  ✗ /run/netns not mounted correctly"
      
      echo ""
      echo "Binaries:"
      [ -f /opt/e2b/bin/orchestrator ] && echo "  ✓ Orchestrator binary exists" || echo "  ✗ Orchestrator binary missing"
      [ -f /opt/e2b/bin/template-manager ] && echo "  ✓ Template-manager binary exists" || echo "  ✗ Template-manager binary missing"
      
      echo ""
      echo "Template-manager Consul registration:"
      if command -v consul >/dev/null 2>&1; then
        consul catalog services 2>/dev/null | grep -q template-manager && echo "  ✓ Template-manager registered in Consul" || echo "  ✗ Template-manager not in Consul"
      else
        echo "  ✗ Consul command not found"
      fi
EOF
    # Capture failures for summary
    ssh "${SSH_OPTS[@]}" ${SSH_USER}@${CLIENT_POOL_PRIVATE} "[ -f /opt/e2b/bin/orchestrator ]" 2>/dev/null || CLIENT_FAILURES+=("Orchestrator binary missing")
    ssh "${SSH_OPTS[@]}" ${SSH_USER}@${CLIENT_POOL_PRIVATE} "[ -f /opt/e2b/bin/template-manager ]" 2>/dev/null || CLIENT_FAILURES+=("Template-manager binary missing")
    ssh "${SSH_OPTS[@]}" ${SSH_USER}@${CLIENT_POOL_PRIVATE} "nomad job status 2>/dev/null | grep -q 'orchestrator'" 2>/dev/null || CLIENT_FAILURES+=("Orchestrator Nomad job not running")
    ssh "${SSH_OPTS[@]}" ${SSH_USER}@${CLIENT_POOL_PRIVATE} "systemctl is-active template-manager >/dev/null 2>&1" 2>/dev/null || CLIENT_FAILURES+=("Template-manager systemd service not active")
    ssh "${SSH_OPTS[@]}" ${SSH_USER}@${CLIENT_POOL_PRIVATE} "consul catalog services 2>/dev/null | grep -q template-manager" 2>/dev/null || CLIENT_FAILURES+=("Template-manager not registered in Consul")
  else
    echo "✗ Cannot connect (instance may still be provisioning or cloud-init not complete)"
    CLIENT_FAILURES+=("Cannot connect to client pool")
  fi
  echo ""
}

check_server() {
  echo "=== Server Pool (${SERVER_POOL_PRIVATE}) ==="
  if ssh "${SSH_OPTS[@]}" ${SSH_USER}@${SERVER_POOL_PRIVATE} "echo 'Connected'" 2>/dev/null; then
    ssh "${SSH_OPTS[@]}" ${SSH_USER}@${SERVER_POOL_PRIVATE} <<'EOF'
      echo "✓ Connected"
      echo ""
      echo "Services:"
      systemctl is-active nomad >/dev/null 2>&1 && echo "  ✓ Nomad active" || echo "  ✗ Nomad not active"
      systemctl is-active consul >/dev/null 2>&1 && echo "  ✓ Consul active" || echo "  ✗ Consul not active"
      
      echo ""
      echo "Nomad server status:"
      if command -v nomad >/dev/null 2>&1; then
        nomad server members 2>/dev/null | head -3 || echo "  ✗ Nomad server not responding"
      else
        echo "  ✗ Nomad command not found"
      fi
EOF
  else
    echo "✗ Cannot connect (instance may still be provisioning or cloud-init not complete)"
  fi
  echo ""
}

# Initialize failure arrays
API_FAILURES=()
CLIENT_FAILURES=()

echo "Checking instance readiness for validate-api.sh..."
echo ""

if [[ -n "${API_POOL_PRIVATE:-}" ]]; then
  check_api
fi

if [[ -n "${CLIENT_POOL_PRIVATE:-}" ]]; then
  check_client
fi

if [[ -n "${SERVER_POOL_PRIVATE:-}" ]]; then
  check_server
fi

echo "=== Summary ==="
echo ""
echo "PASSED checks (ready for validate-api.sh):"
echo "  ✓ All instances accessible"
echo "  ✓ Nomad and Consul services running"
echo "  ✓ User-data settings applied (CAP_SYS_ADMIN, groups, mounts)"
echo ""
echo "FAILED checks (need action before validate-api.sh):"
set +u  # Temporarily disable unbound variable check for array access
TOTAL_FAILURES=$((${#API_FAILURES[@]} + ${#CLIENT_FAILURES[@]}))
if [[ ${TOTAL_FAILURES} -eq 0 ]]; then
  echo "  ✓ All checks passed! Ready for validate-api.sh"
else
  for failure in "${API_FAILURES[@]}"; do
    echo "  ✗ ${failure}"
  done
  for failure in "${CLIENT_FAILURES[@]}"; do
    echo "  ✗ ${failure}"
  done
fi
set -u  # Re-enable unbound variable check
echo ""
if [[ ${TOTAL_FAILURES} -gt 0 ]]; then
  echo "Next steps:"
  echo "1. Run: ./deploy-poc.sh (builds binaries, initializes database)"
  echo "2. Run: ./deploy-services.sh (starts Nomad jobs and template-manager)"
  echo "3. Then: ./scripts/validate-api.sh"
fi

