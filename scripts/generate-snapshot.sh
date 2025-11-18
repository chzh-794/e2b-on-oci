#!/bin/bash
# Generate and capture a Firecracker snapshot for an E2B sandbox on OCI
#
# This helper will optionally create a sandbox from a template, pause it via the
# public API so that orchestrator uploads the snapshot artifacts, and then show
# where the snapshot files are stored.
#
# Usage examples:
#   E2B_API_ENDPOINT=http://129.149.60.176 \
#   E2B_API_KEY=$(cat ~/.config/e2b/api.key) \
#   ./scripts/generate-snapshot.sh --template base-poc --orchestrator-host 129.149.61.235
#
#   ./scripts/generate-snapshot.sh --sandbox-id sbx_abc123 --storage-path /var/e2b/templates
#
# Required tools: curl, jq, ssh (optional if orchestrator introspection is used)

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: generate-snapshot.sh [options]

Options:
  --template <template-or-alias>  Template alias/ID to spawn a sandbox from.
                                  Required when --sandbox-id is not supplied.
  --sandbox-id <sandbox-id>       Reuse an existing running sandbox instead of
                                  creating a new one.
  --timeout <seconds>             Sandbox TTL when creating a new sandbox (default: 300).
  --api-endpoint <url>            Override API endpoint (default: $E2B_API_ENDPOINT).
  --api-key <key>                 Explicit API key value (default: $E2B_API_KEY).
  --api-key-file <path>           Read API key from file (alternative to --api-key).
  --storage-path <path>           Root path where snapshots land (default: /var/e2b/templates).
  --orchestrator-host <host>      SSH host to inspect snapshot artifacts (optional).
  --ssh-user <user>               SSH username for orchestrator host (default: ubuntu).
  --ssh-key <path>                SSH private key for orchestrator host (default: ~/.ssh/id_rsa).
  --bastion-host <host>           Optional bastion host for SSH proxy jump.
  --keep-sandbox                  Do not delete sandbox after pausing (default: delete if we created it).
  --help                          Show this help message.

Environment variables:
  E2B_API_ENDPOINT  Default API endpoint.
  E2B_API_KEY       Default API key (overridden by --api-key / --api-key-file).

EOF
  exit 1
}

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command '$1' is not available" >&2
    exit 1
  fi
}

require_cmd curl
require_cmd jq

API_ENDPOINT="${E2B_API_ENDPOINT:-}"
API_KEY="${E2B_API_KEY:-}"
TEMPLATE_INPUT=""
SANDBOX_ID=""
SANDBOX_TIMEOUT=300
STORAGE_PATH="/var/e2b/templates"
ORCH_HOST=""
SSH_USER="ubuntu"
SSH_KEY_PATH="${HOME}/.ssh/id_rsa"
BASTION_HOST=""
KEEP_SANDBOX=false
CREATE_SANDBOX=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --template)
      TEMPLATE_INPUT="$2"
      shift 2
      ;;
    --sandbox-id)
      SANDBOX_ID="$2"
      shift 2
      ;;
    --timeout)
      SANDBOX_TIMEOUT="$2"
      shift 2
      ;;
    --api-endpoint)
      API_ENDPOINT="$2"
      shift 2
      ;;
    --api-key)
      API_KEY="$2"
      shift 2
      ;;
    --api-key-file)
      API_KEY="$(<"$2")"
      shift 2
      ;;
    --storage-path)
      STORAGE_PATH="$2"
      shift 2
      ;;
    --orchestrator-host)
      ORCH_HOST="$2"
      shift 2
      ;;
    --ssh-user)
      SSH_USER="$2"
      shift 2
      ;;
    --ssh-key)
      SSH_KEY_PATH="$2"
      shift 2
      ;;
    --bastion-host)
      BASTION_HOST="$2"
      shift 2
      ;;
    --keep-sandbox)
      KEEP_SANDBOX=true
      shift 1
      ;;
    --help|-h)
      usage
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      ;;
  esac
done

if [[ -z "$API_ENDPOINT" ]]; then
  echo "Error: API endpoint not provided (set E2B_API_ENDPOINT or use --api-endpoint)" >&2
  exit 1
fi

if [[ -z "$API_KEY" ]]; then
  echo "Error: API key not provided (set E2B_API_KEY, --api-key, or --api-key-file)" >&2
  exit 1
fi

if [[ -z "$SANDBOX_ID" && -z "$TEMPLATE_INPUT" ]]; then
  echo "Error: provide --template when not reusing an existing sandbox" >&2
  exit 1
fi

TMP_RESP="$(mktemp)"
trap 'rm -f "$TMP_RESP"' EXIT

created_sandbox=false
cleanup_sandbox() {
  if $created_sandbox && ! $KEEP_SANDBOX; then
    log "Deleting sandbox $SANDBOX_ID"
    curl -s -o /dev/null -w "%{http_code}" -X DELETE \
      -H "X-API-Key: ${API_KEY}" \
      "${API_ENDPOINT%/}/sandboxes/${SANDBOX_ID}" >/dev/null || true
  fi
}
trap 'cleanup_sandbox' EXIT

# Helper to make authenticated curl calls
api_curl() {
  curl -sS -H "X-API-Key: ${API_KEY}" "$@"
}

if [[ -z "$SANDBOX_ID" ]]; then
  log "Creating sandbox from template '${TEMPLATE_INPUT}' (timeout ${SANDBOX_TIMEOUT}s)"
  create_payload=$(jq -nc --arg tpl "$TEMPLATE_INPUT" --argjson timeout "$SANDBOX_TIMEOUT" '{templateID: $tpl, timeout: $timeout}')
  http_code=$(curl -s -o "$TMP_RESP" -w "%{http_code}" -X POST \
    -H "X-API-Key: ${API_KEY}" \
    -H 'Content-Type: application/json' \
    -d "$create_payload" \
    "${API_ENDPOINT%/}/sandboxes")
  if [[ "$http_code" != "201" ]]; then
    echo "Error: sandbox creation failed (HTTP $http_code)" >&2
    cat "$TMP_RESP" >&2 || true
    exit 1
  fi

  SANDBOX_ID=$(jq -r '.sandboxID // empty' "$TMP_RESP")
  TEMPLATE_ID=$(jq -r '.templateID // empty' "$TMP_RESP")
  if [[ -z "$SANDBOX_ID" ]]; then
    echo "Error: sandbox ID missing in create response" >&2
    cat "$TMP_RESP" >&2 || true
    exit 1
  fi
  created_sandbox=true
  log "Sandbox created: $SANDBOX_ID (template ${TEMPLATE_ID:-$TEMPLATE_INPUT})"
else
  log "Using existing sandbox $SANDBOX_ID"
  TEMPLATE_ID="$TEMPLATE_INPUT"
fi

# Resolve template + build metadata for locating artifacts
TEMPLATE_ID_RESOLVED="$TEMPLATE_ID"
BUILD_ID=""
if [[ -n "$TEMPLATE_INPUT" ]]; then
  log "Fetching template metadata"
  template_http=$(curl -s -o "$TMP_RESP" -w "%{http_code}" \
    -H "X-API-Key: ${API_KEY}" "${API_ENDPOINT%/}/templates")
  if [[ "$template_http" == "200" ]]; then
    TEMPLATE_ID_RESOLVED=$(jq -r --arg input "$TEMPLATE_INPUT" 'map(select(.templateID == $input or (.aliases != null and (.aliases[]? == $input)))) | first | .templateID // empty' "$TMP_RESP")
    BUILD_ID=$(jq -r --arg input "$TEMPLATE_INPUT" 'map(select(.templateID == $input or (.aliases != null and (.aliases[]? == $input)))) | first | .buildID // empty' "$TMP_RESP")
    if [[ -z "$BUILD_ID" ]]; then
      log "Warning: could not resolve build ID for template '${TEMPLATE_INPUT}'. Snapshot files may still be uploaded but path detection will be limited."
    else
      log "Resolved template ID: ${TEMPLATE_ID_RESOLVED} (build ${BUILD_ID})"
    fi
  else
    log "Warning: unable to fetch template metadata (HTTP ${template_http})"
  fi
fi

log "Pausing sandbox ${SANDBOX_ID}"
http_code=$(curl -s -o "$TMP_RESP" -w "%{http_code}" -X POST \
  -H "X-API-Key: ${API_KEY}" \
  "${API_ENDPOINT%/}/sandboxes/${SANDBOX_ID}/pause")
if [[ "$http_code" != "204" ]]; then
  echo "Error: pause request failed (HTTP $http_code)" >&2
  cat "$TMP_RESP" >&2 || true
  exit 1
fi

log "Pause request accepted – waiting for snapshot metadata to become available"
PAUSE_TIMEOUT=180
SLEEP_INTERVAL=5
elapsed=0
while (( elapsed < PAUSE_TIMEOUT )); do
  http_code=$(curl -s -o "$TMP_RESP" -w "%{http_code}" -H "X-API-Key: ${API_KEY}" "${API_ENDPOINT%/}/sandboxes/${SANDBOX_ID}") || http_code="000"
  if [[ "$http_code" == "200" ]]; then
    state=$(jq -r '.state // empty' "$TMP_RESP")
    if [[ "$state" == "paused" ]]; then
      log "Snapshot recorded for sandbox ${SANDBOX_ID}"
      break
    fi
  elif [[ "$http_code" == "404" ]]; then
    # Snapshot might not be indexed yet – continue waiting
    true
  else
    log "Received HTTP ${http_code} while polling snapshot status"
  fi
  sleep "$SLEEP_INTERVAL"
  elapsed=$((elapsed + SLEEP_INTERVAL))
  if (( elapsed % 30 == 0 )); then
    log "Still waiting (${elapsed}s elapsed)"
  fi

done

if (( elapsed >= PAUSE_TIMEOUT )); then
  echo "Error: timed out waiting for sandbox to pause" >&2
  exit 1
fi

if [[ -n "$BUILD_ID" ]]; then
  SNAPSHOT_DIR="${STORAGE_PATH%/}/${BUILD_ID}"
  log "Snapshot artifacts expected under ${SNAPSHOT_DIR}"
else
  log "Snapshot artifacts expected under ${STORAGE_PATH} (build ID unresolved)"
fi

if [[ -n "$ORCH_HOST" && -n "$BUILD_ID" ]]; then
  log "Inspecting snapshot directory on ${ORCH_HOST}"
  SSH_OPTS=(-i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no)
  if [[ -n "$BASTION_HOST" ]]; then
    SSH_OPTS+=(-o "ProxyJump=${SSH_USER}@${BASTION_HOST}")
  fi
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${ORCH_HOST}" "ls -lh ${SNAPSHOT_DIR}" || log "Warning: could not list snapshot directory via SSH"
fi

log "Snapshot generation complete"

cat <<EOF
Summary
-------
Sandbox ID : ${SANDBOX_ID}
Template   : ${TEMPLATE_ID_RESOLVED:-${TEMPLATE_INPUT:-unknown}}
Build ID   : ${BUILD_ID:-unknown}
Storage    : ${STORAGE_PATH}
Snapshot   : ${BUILD_ID:+${STORAGE_PATH%/}/${BUILD_ID} (rootfs.ext4, memfile, snapfile)}
EOF



