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

REQUIRED=(BASTION_HOST SERVER_POOL_PUBLIC API_POOL_PUBLIC CLIENT_POOL_PUBLIC POSTGRES_HOST SERVER_POOL_PRIVATE)
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
if ! ssh_jump_quiet "${CLIENT_HOST}" true; then
  CLIENT_HOST=${CLIENT_POOL_PUBLIC}
fi

SERVER_HOST=${SERVER_POOL_PRIVATE:-$SERVER_POOL_PUBLIC}
NOMAD_HTTP="http://${SERVER_HOST}:4646"

echo "═══════════════════════════════════════════════════════════"
echo "Post-Deployment Verification"
echo "═══════════════════════════════════════════════════════════"
echo ""

echo "════════ Critical Nomad Jobs ════════"
JOBS=(orchestrator template-manager api client-proxy)
overall_rc=0

# Use Nomad CLI via bastion (simpler and more reliable)
SSH_BASE=(-i "${SSH_KEY}" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile="${KNOWN_HOSTS_FILE}")

ssh "${SSH_BASE[@]}" "${SSH_USER}@${BASTION_HOST}" bash <<EOF
set -euo pipefail

SERVER_POOL_PRIVATE="${SERVER_POOL_PRIVATE}"
NOMAD_ADDR="http://\${SERVER_POOL_PRIVATE}:4646"

NOMAD_BIN=""
if command -v nomad >/dev/null 2>&1; then
  NOMAD_BIN="\$(command -v nomad)"
elif [[ -x /opt/nomad/bin/nomad ]]; then
  NOMAD_BIN="/opt/nomad/bin/nomad"
elif [[ -x /usr/local/bin/nomad ]]; then
  NOMAD_BIN="/usr/local/bin/nomad"
else
  echo "Nomad CLI not found on bastion." >&2
  exit 1
fi

export NOMAD_ADDR

JOBS=(orchestrator template-manager api client-proxy)
overall_rc=0

for job in "\${JOBS[@]}"; do
  echo ""
  echo "Job: \${job}"
  JSON_FILE="/tmp/job-\${job}.json"
  if ! "\${NOMAD_BIN}" job status -json "\${job}" >"\${JSON_FILE}" 2>/dev/null; then
    echo "  CRITICAL: job \${job} not found in Nomad."
    echo "  → Run: ./deploy-services.sh to register the job"
    overall_rc=1
    continue
  fi
  
  # Debug: Check if file exists and has content
  if [[ ! -f "\${JSON_FILE}" ]]; then
    echo "  ERROR: JSON file not created: \${JSON_FILE}"
    overall_rc=1
    continue
  fi
  
  FILE_SIZE=\$(stat -f%z "\${JSON_FILE}" 2>/dev/null || stat -c%s "\${JSON_FILE}" 2>/dev/null || echo "0")
  if [[ "\${FILE_SIZE}" -eq 0 ]]; then
    echo "  ERROR: JSON file is empty: \${JSON_FILE}"
    overall_rc=1
    continue
  fi
  
  set +e  # Temporarily disable exit on error to capture Python exit code
  python3 - "\${job}" "\${JSON_FILE}" <<'PY'
import json
import sys
job = sys.argv[1]
json_file = sys.argv[2]
try:
    with open(json_file, "r") as f:
        data = json.load(f)
    # nomad job status -json returns a list, get first element
    if isinstance(data, list):
        data = data[0] if data else {}
    
    # Summary is nested: data['Summary']['Summary']['task-group-name']
    summary = data.get("Summary", {})
    if not summary:
        print(f"  ERROR: No Summary found in job data")
        print(f"  Available keys: {list(data.keys())}")
        sys.exit(1)
    
    task_group_summary = summary.get("Summary", {})
    if not task_group_summary:
        print(f"  ERROR: No task group Summary found")
        print(f"  Summary keys: {list(summary.keys())}")
        print(f"  Full Summary: {json.dumps(summary, indent=2)}")
        sys.exit(1)
    
    # Sum up all task groups (some jobs have multiple task groups)
    total_running = 0
    total_pending = 0
    total_failed = 0
    total_dead = 0
    
    for tg_name, tg_data in task_group_summary.items():
        total_running += tg_data.get("Running", 0)
        total_pending += tg_data.get("Pending", 0)
        total_failed += tg_data.get("Failed", 0)
        total_dead += tg_data.get("Dead", 0)
    
    print(f"  Running={total_running} Pending={total_pending} Failed={total_failed} Dead={total_dead}")
    if total_running <= 0:
        print(f"  CRITICAL: job {job} has no running allocations.")
        if total_pending > 0:
            print(f"  → {total_pending} allocation(s) pending - check node placement constraints")
        if total_failed > 0:
            print(f"  → {total_failed} allocation(s) failed - check: nomad job status {job}")
        if total_dead > 0:
            print(f"  → {total_dead} allocation(s) dead - check: nomad alloc status <alloc-id>")
        sys.exit(1)
except Exception as e:
    print(f"  ERROR: Failed to parse job data: {e}")
    import traceback
    traceback.print_exc()
    sys.exit(1)
PY
  rc=$?
  set -e  # Re-enable exit on error
  if [[ \$rc -ne 0 ]]; then
    overall_rc=1
    # Show recent allocations for failed jobs
    echo "  Recent allocations:"
    "\${NOMAD_BIN}" job status "\${job}" 2>/dev/null | grep -A 5 "Allocations" || true
  fi
done

echo ""
echo "════════ End Critical Jobs Summary ════════"
exit \$overall_rc
EOF

rc=$?
if [[ $rc -ne 0 ]]; then
  overall_rc=1
  echo ""
  echo "✗ One or more critical Nomad jobs are not healthy."
  echo ""
  echo "Troubleshooting steps:"
  echo "  1. Check if jobs are registered: ssh -J ${SSH_USER}@${BASTION_HOST} ${SSH_USER}@${SERVER_POOL_PRIVATE} 'nomad job status'"
  echo "  2. If jobs are missing, run: ./deploy-services.sh"
  echo "  3. If jobs exist but aren't running, check placement:"
  echo "     ssh -J ${SSH_USER}@${BASTION_HOST} ${SSH_USER}@${SERVER_POOL_PRIVATE} 'nomad job status <job-name>'"
  echo "  4. Check allocation failures:"
  echo "     ssh -J ${SSH_USER}@${BASTION_HOST} ${SSH_USER}@${SERVER_POOL_PRIVATE} 'nomad alloc status <alloc-id>'"
  echo "  5. Verify node classes match job constraints:"
  echo "     ssh -J ${SSH_USER}@${BASTION_HOST} ${SSH_USER}@${SERVER_POOL_PRIVATE} 'nomad node status'"
else
  echo ""
  echo "✓ All critical Nomad jobs have at least one running allocation."
fi
echo ""

echo "═══════════════════════════════════════════════════════════"
echo "Service Health Checks"
echo "═══════════════════════════════════════════════════════════"
echo ""

echo "== Nomad server health =="
ssh_jump "${API_HOST}" "curl -sf ${NOMAD_HTTP}/v1/status/leader && echo '✓ Leader: OK' || echo '✗ Leader check failed'"
ssh_jump "${API_HOST}" "curl -sf ${NOMAD_HTTP}/v1/status/peers && echo '✓ Peers: OK' || echo '✗ Peers check failed'"
echo ""

echo "== API service health =="
if ssh_jump "${API_HOST}" 'curl -sf http://127.0.0.1:50001/health >/dev/null 2>&1'; then
  echo "✓ API health check: OK"
else
  echo "✗ API health check: FAILED"
fi
echo ""

echo "== Client proxy service health =="
if ssh_jump "${API_HOST}" 'curl -sf http://127.0.0.1:3001/health >/dev/null 2>&1'; then
  echo "✓ Client proxy health check: OK"
else
  echo "✗ Client proxy health check: FAILED"
fi
echo ""

echo "== API service ports =="
ssh_jump "${API_HOST}" 'if sudo -n true 2>/dev/null; then sudo -n ss -ltnp | grep -E "50001|3001" || echo "No services listening"; else ss -ltnp | grep -E "50001|3001" || echo "No services listening"; fi'
echo ""

echo "== PostgreSQL connectivity from API node =="
if ssh_jump "${API_HOST}" "PGPASSWORD='${POSTGRES_PASSWORD}' psql 'postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}?sslmode=require' -c 'select 1;' >/dev/null 2>&1"; then
  echo "✓ PostgreSQL connection: OK"
else
  echo "✗ PostgreSQL connection: FAILED"
fi
echo ""

echo "== Consul service discovery =="
SERVICE_COUNT=$(ssh_jump "${API_HOST}" 'curl -sf http://127.0.0.1:8500/v1/catalog/services 2>/dev/null | jq length || echo "0"')
echo "Registered services: ${SERVICE_COUNT}"
if [[ "${SERVICE_COUNT}" -gt 0 ]]; then
  echo "✓ Consul service catalog: OK"
  ssh_jump "${API_HOST}" 'curl -sf http://127.0.0.1:8500/v1/catalog/services 2>/dev/null | jq -r "keys[]" | sort'
else
  echo "✗ Consul service catalog: EMPTY or UNREACHABLE"
fi
echo ""

echo "== Consul cluster membership and health =="
echo "API Pool Consul status:"
API_CONSUL_MEMBERS=$(ssh_jump "${API_HOST}" '/usr/local/bin/consul members 2>/dev/null | grep -E "(server|client)" || echo ""')
if [[ -n "${API_CONSUL_MEMBERS}" ]]; then
  echo "${API_CONSUL_MEMBERS}"
  # Check if API pool Consul agent is healthy
  API_CONSUL_HEALTH=$(ssh_jump "${API_HOST}" 'curl -sf http://127.0.0.1:8500/v1/agent/self 2>/dev/null | jq -r ".Config.NodeName // empty" || echo ""' 2>/dev/null || echo "")
  if [[ -n "${API_CONSUL_HEALTH}" ]]; then
    echo "  ✓ API Pool Consul agent is healthy"
  else
    echo "  ✗ API Pool Consul agent health check failed"
    overall_rc=1
  fi
else
  echo "  ✗ Consul not connected on API pool"
  overall_rc=1
fi

echo "Client Pool Consul status:"
CLIENT_CONSUL_MEMBERS=$(ssh_jump "${CLIENT_HOST}" '/usr/local/bin/consul members 2>/dev/null | grep -E "(server|client)" || echo ""')
if [[ -n "${CLIENT_CONSUL_MEMBERS}" ]]; then
  echo "${CLIENT_CONSUL_MEMBERS}"
  # Check if client pool Consul agent is healthy (via API pool since client may not expose 8500)
  CLIENT_CONSUL_NODE=$(echo "${CLIENT_CONSUL_MEMBERS}" | head -1 | awk '{print $1}' || echo "")
  if [[ -n "${CLIENT_CONSUL_NODE}" ]]; then
    echo "  ✓ Client Pool Consul agent is connected"
  else
    echo "  ⚠ Could not verify Client Pool Consul agent health"
  fi
else
  echo "  ✗ Consul not connected on Client pool"
  overall_rc=1
fi
echo ""

echo "== Nomad client node status and class validation =="
NODE_DATA=$(ssh_jump "${API_HOST}" "curl -sf ${NOMAD_HTTP}/v1/nodes 2>/dev/null" || echo "")
if [[ -z "${NODE_DATA}" ]]; then
  echo "✗ ERROR: Could not query Nomad nodes"
else
  echo "Node status:"
  ssh_jump "${API_HOST}" "curl -sf ${NOMAD_HTTP}/v1/nodes 2>/dev/null | jq -r '.[] | select(.Status == \"ready\") | [.ID, .Name, .Status, (.NodeClass // \"none\")] | @tsv'"
  
  # Validate node classes match job requirements
  echo ""
  echo "Node class validation (required for job placement):"
  # Filter by NodeClass directly (not by Name, since OCI node names are OCIDs)
  API_NODE_CLASS=$(echo "${NODE_DATA}" | jq -r '.[] | select(.Status == "ready" and .NodeClass == "api") | .NodeClass' | head -1)
  CLIENT_NODE_CLASS=$(echo "${NODE_DATA}" | jq -r '.[] | select(.Status == "ready" and .NodeClass == "client") | .NodeClass' | head -1)
  
  if [[ "${API_NODE_CLASS}" == "api" ]]; then
    echo "  ✓ API pool node.class = 'api' (required by 'api' job)"
  elif [[ -n "${API_NODE_CLASS}" ]]; then
    echo "  ✗ CRITICAL: API pool node.class = '${API_NODE_CLASS}' (expected 'api')"
    echo "    The 'api' job will fail to place!"
    overall_rc=1
  else
    echo "  ⚠ WARNING: Could not determine API pool node.class"
  fi
  
  if [[ "${CLIENT_NODE_CLASS}" == "client" ]]; then
    echo "  ✓ Client pool node.class = 'client' (required by 'orchestrator' and 'template-manager' jobs)"
  elif [[ -n "${CLIENT_NODE_CLASS}" ]]; then
    echo "  ✗ CRITICAL: Client pool node.class = '${CLIENT_NODE_CLASS}' (expected 'client')"
    echo "    The 'orchestrator' and 'template-manager' jobs will fail to place!"
    overall_rc=1
  else
    echo "  ⚠ WARNING: Could not determine Client pool node.class"
  fi
fi

echo ""
echo "== Template builder availability (critical for template builds) =="
# Check if API and client-proxy are running (required for template builder discovery)
API_HEALTH=$(ssh_jump "${API_HOST}" 'curl -sf http://127.0.0.1:50001/health >/dev/null 2>&1 && echo "OK" || echo "FAILED"' 2>/dev/null || echo "FAILED")
CLIENT_PROXY_HEALTH=$(ssh_jump "${API_HOST}" 'curl -sf http://127.0.0.1:3001/health >/dev/null 2>&1 && echo "OK" || echo "FAILED"' 2>/dev/null || echo "FAILED")

TEMPLATE_BUILDER_CHECK_FAILED=0
if [[ "${API_HEALTH}" != "OK" ]] || [[ "${CLIENT_PROXY_HEALTH}" != "OK" ]]; then
  echo "   ✗ ERROR: API or client-proxy not running - cannot check template builders"
  overall_rc=1
  TEMPLATE_BUILDER_CHECK_FAILED=1
else
  # Try to query template builders via edge API (requires EDGE_SERVICE_SECRET)
  # Use CONFIG_FILE which is already set at the top of the script
  # EDGE_SERVICE_SECRET is defined in deploy-poc.sh, use default if not in deploy.env
  if [[ -f "${CONFIG_FILE}" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${CONFIG_FILE}" 2>/dev/null || true
    set +a
  fi
  
  # Use EDGE_SERVICE_SECRET from deploy.env if set, otherwise use the default from deploy-poc.sh
  EDGE_SERVICE_SECRET=${EDGE_SERVICE_SECRET:-"E2bEdgeSecret2025!"}
  
  # Query the edge API for orchestrators
  ORCHESTRATORS_JSON=$(ssh_jump "${API_HOST}" "curl -sf -H 'X-API-Key: ${EDGE_SERVICE_SECRET}' http://127.0.0.1:3001/v1/service-discovery/orchestrators 2>/dev/null" || echo "")
  
  # Check if API call succeeded (empty response or invalid JSON means API error)
  if [[ -z "${ORCHESTRATORS_JSON}" ]] || ! echo "${ORCHESTRATORS_JSON}" | jq empty >/dev/null 2>&1; then
    echo "   ⚠ WARNING: Failed to query orchestrator API"
    echo "     Response: ${ORCHESTRATORS_JSON:-"(empty)"}"
    echo "     Check: client-proxy health, EDGE_SERVICE_SECRET authentication, API endpoint"
    echo "     Note: Template builds can still work using local template manager (template-manager service)"
    TEMPLATE_BUILDER_WARNING="Template builder check failed (API request failed or returned invalid JSON). Template builds will use local template manager as fallback."
    # Don't fail the check - template builds can use local template manager as fallback
  else
    # Normalize empty response to empty array
    if [[ "${ORCHESTRATORS_JSON}" == "" ]]; then
      ORCHESTRATORS_JSON="[]"
    fi
    # Parse the JSON response
    ORCHESTRATOR_COUNT=$(echo "${ORCHESTRATORS_JSON}" | jq -r 'length // 0' 2>/dev/null || echo "0")
    BUILDER_COUNT=$(echo "${ORCHESTRATORS_JSON}" | jq -r '[.[] | select(.Roles[]? == "template-builder")] | length' 2>/dev/null || echo "0")
    
    if [[ "${ORCHESTRATOR_COUNT}" -gt 0 ]]; then
      echo "   Orchestrators discovered: ${ORCHESTRATOR_COUNT}"
    fi
    
    if [[ "${BUILDER_COUNT}" -gt 0 ]]; then
      echo "   ✓ Template builders available (${BUILDER_COUNT} nodes with template-builder role)"
      TEMPLATE_BUILDER_STATUS="ok"
    else
      echo "   ⚠ WARNING: No cluster template builders available"
      if [[ "${ORCHESTRATOR_COUNT}" -gt 0 ]]; then
        echo "     Found ${ORCHESTRATOR_COUNT} orchestrator(s) but none have the 'template-builder' role"
        echo "     Orchestrator details:"
        echo "${ORCHESTRATORS_JSON}" | jq -r '.[] | "      - NodeID: \(.NodeID // "unknown"), Status: \(.ServiceStatus // "unknown"), Roles: \(.Roles | join(", ") // "none")"' 2>/dev/null || echo "      (Could not parse orchestrator details)"
        TEMPLATE_BUILDER_WARNING="No cluster template builders available (${ORCHESTRATOR_COUNT} orchestrator(s) found but none have template-builder role). Template builds will use local template manager as fallback."
      else
        echo "     No orchestrators discovered by client-proxy"
        echo "     Possible causes:"
        echo "       - Orchestrator not registered in Consul (check Consul service catalog)"
        echo "       - Client-proxy cannot establish gRPC connection to orchestrator (TCP port 5008 may be reachable, but gRPC handshake fails)"
        echo "       - Orchestrator gRPC service not responding to ServiceInfo() calls"
        echo "       - Orchestrator not ready yet (may need time to start)"
        echo "     Check client-proxy logs for 'Error connecting to node' or 'failed to initialize orchestrator'"
        echo "     Check orchestrator logs to verify gRPC service is running on port 5008"
        TEMPLATE_BUILDER_WARNING="No cluster template builders available (no orchestrators discovered by client-proxy). Template builds will use local template manager as fallback."
      fi
      echo "     Note: Template builds can still work using local template manager (template-manager service)"
      echo "     Run ./scripts/debug-template-builders.sh for detailed diagnostics"
      # Don't fail the check - template builds can use local template manager as fallback
    fi
  fi
fi

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "Post-Deployment Check Summary"
echo "═══════════════════════════════════════════════════════════"
echo ""

# Count checks
PASSED=0
FAILED=0
WARNINGS=0
FAILED_ITEMS=()
WARNED_ITEMS=()

# Count job status (use same logic as main check above)
JOBS_OK=0
JOBS_FAILED=0
# Re-use the results from the main check section - no need to check again
# The main check already validated all jobs have running allocations
# If we got here, the main check passed, so all jobs are OK
for job in orchestrator template-manager api client-proxy; do
  JOBS_OK=$((JOBS_OK + 1))
done

# Count health checks
if ssh_jump "${API_HOST}" 'curl -sf http://127.0.0.1:50001/health >/dev/null 2>&1'; then
  PASSED=$((PASSED + 1))
else
  FAILED=$((FAILED + 1))
  FAILED_ITEMS+=("API health check failed")
fi

if ssh_jump "${API_HOST}" 'curl -sf http://127.0.0.1:3001/health >/dev/null 2>&1'; then
  PASSED=$((PASSED + 1))
else
  FAILED=$((FAILED + 1))
  FAILED_ITEMS+=("Client proxy health check failed")
fi

if ssh_jump "${API_HOST}" "PGPASSWORD='${POSTGRES_PASSWORD}' psql 'postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}?sslmode=require' -c 'select 1;' >/dev/null 2>&1"; then
  PASSED=$((PASSED + 1))
else
  FAILED=$((FAILED + 1))
  FAILED_ITEMS+=("PostgreSQL connection failed")
fi

SERVICE_COUNT=$(ssh_jump "${API_HOST}" 'curl -sf http://127.0.0.1:8500/v1/catalog/services 2>/dev/null | jq length || echo "0"')
if [[ "${SERVICE_COUNT}" -gt 0 ]]; then
  PASSED=$((PASSED + 1))
else
  WARNINGS=$((WARNINGS + 1))
  WARNED_ITEMS+=("Consul service catalog is empty or unreachable")
fi

# Consul agent health check
API_CONSUL_HEALTH=$(ssh_jump "${API_HOST}" 'curl -sf http://127.0.0.1:8500/v1/agent/self 2>/dev/null | jq -r ".Config.NodeName // empty" || echo ""' 2>/dev/null || echo "")
if [[ -n "${API_CONSUL_HEALTH}" ]]; then
  PASSED=$((PASSED + 1))
else
  FAILED=$((FAILED + 1))
  FAILED_ITEMS+=("API Pool Consul agent health check failed")
fi

# Node class validation
NODE_DATA=$(ssh_jump "${API_HOST}" "curl -sf ${NOMAD_HTTP}/v1/nodes 2>/dev/null" || echo "")
# Filter by NodeClass directly (not by Name, since OCI node names are OCIDs)
API_NODE_CLASS=$(echo "${NODE_DATA}" | jq -r '.[] | select(.Status == "ready" and .NodeClass == "api") | .NodeClass' | head -1)
CLIENT_NODE_CLASS=$(echo "${NODE_DATA}" | jq -r '.[] | select(.Status == "ready" and .NodeClass == "client") | .NodeClass' | head -1)

if [[ "${API_NODE_CLASS}" == "api" ]]; then
  PASSED=$((PASSED + 1))
else
  if [[ -n "${API_NODE_CLASS}" ]]; then
    FAILED=$((FAILED + 1))
    FAILED_ITEMS+=("API pool node.class is '${API_NODE_CLASS}' (expected 'api')")
  else
    WARNINGS=$((WARNINGS + 1))
    WARNED_ITEMS+=("Could not determine API pool node.class")
  fi
fi

if [[ "${CLIENT_NODE_CLASS}" == "client" ]]; then
  PASSED=$((PASSED + 1))
else
  if [[ -n "${CLIENT_NODE_CLASS}" ]]; then
    FAILED=$((FAILED + 1))
    FAILED_ITEMS+=("Client pool node.class is '${CLIENT_NODE_CLASS}' (expected 'client')")
  else
    WARNINGS=$((WARNINGS + 1))
    WARNED_ITEMS+=("Could not determine Client pool node.class")
  fi
fi

# Template builder check result (warning, not failure - can fallback to local template manager)
if [[ -n "${TEMPLATE_BUILDER_STATUS:-}" ]] && [[ "${TEMPLATE_BUILDER_STATUS}" == "ok" ]]; then
  PASSED=$((PASSED + 1))
elif [[ -n "${TEMPLATE_BUILDER_WARNING:-}" ]]; then
  WARNINGS=$((WARNINGS + 1))
  WARNED_ITEMS+=("${TEMPLATE_BUILDER_WARNING}")
elif [[ -n "${TEMPLATE_BUILDER_ERROR:-}" ]]; then
  # Legacy error handling - convert to warning since fallback is available
  WARNINGS=$((WARNINGS + 1))
  WARNED_ITEMS+=("${TEMPLATE_BUILDER_ERROR}")
fi

echo "  ✓ Passed:  ${PASSED}"
if [[ ${WARNINGS} -gt 0 ]]; then
  echo "  ⚠ Warnings: ${WARNINGS}"
  echo ""
  echo "  Warning items:"
  for item in "${WARNED_ITEMS[@]}"; do
    echo "    - ${item}"
  done
fi
if [[ ${FAILED} -gt 0 ]] || [[ ${JOBS_FAILED} -gt 0 ]]; then
  TOTAL_FAILED=$((FAILED + JOBS_FAILED))
  echo "  ✗ Failed:  ${TOTAL_FAILED}"
  echo ""
  echo "  Failed items:"
  for item in "${FAILED_ITEMS[@]}"; do
    echo "    - ${item}"
  done
fi
echo ""

if [[ $overall_rc -eq 0 ]] && [[ ${FAILED} -eq 0 ]] && [[ ${JOBS_FAILED} -eq 0 ]]; then
  echo "✅ All critical checks passed!"
  echo ""
  echo "All critical services are running. You can proceed with API validation."
  echo "Run: ./scripts/validate-api.sh"
  exit 0
else
  echo "❌ Some critical checks failed. Please review the errors above."
  echo ""
  echo "After fixing issues, you can proceed with API validation."
  exit 1
fi

