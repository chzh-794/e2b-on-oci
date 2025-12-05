#!/bin/bash

set -euo pipefail

log() {
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "${timestamp} [nomad-bootstrap] $*"
}

NOMAD_BIN_DIR="/opt/nomad/bin"
NOMAD_CONFIG_DIR="/opt/nomad/config"
NOMAD_DATA_DIR="/opt/nomad/data"
NOMAD_USER="root"
NOMAD_SERVICE_PATH="/etc/systemd/system/nomad.service"

CONSUL_TOKEN=""
CLUSTER_SIZE=""
COMPARTMENT_OCID=""
CLUSTER_ROLE="server"
REGION_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster-size)
      CLUSTER_SIZE="$2"
      shift 2
      ;;
    --compartment-id)
      COMPARTMENT_OCID="$2"
      shift 2
      ;;
    --cluster-role)
      CLUSTER_ROLE="$2"
      shift 2
      ;;
    --region)
      REGION_OVERRIDE="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$COMPARTMENT_OCID" ]]; then
  echo "Missing required arguments." >&2
  exit 1
fi

if [[ -z "$CLUSTER_SIZE" ]]; then
  CLUSTER_SIZE="3"
fi

METADATA_URL="http://169.254.169.254/opc/v2"
METADATA_HEADER="Authorization: Bearer Oracle"
metadata() {
  local path="$1"
  curl -sSL -H "$METADATA_HEADER" "$METADATA_URL/$path"
}

INSTANCE_JSON=$(metadata "instance/")
if [[ -z "$INSTANCE_JSON" ]]; then
  echo "Unable to retrieve instance metadata." >&2
  exit 1
fi

INSTANCE_ID=$(echo "$INSTANCE_JSON" | jq -r '.id')
# Use canonicalRegionName (e.g., us-ashburn-1) to keep region/datacenter aligned
# across servers and clients. Fall back to short region code if canonical is missing.
CANONICAL_REGION=$(echo "$INSTANCE_JSON" | jq -r '.canonicalRegionName // empty')
if [[ -z "$CANONICAL_REGION" || "$CANONICAL_REGION" == "null" ]]; then
  CANONICAL_REGION=$(echo "$INSTANCE_JSON" | jq -r '.region')
fi
REGION=${REGION_OVERRIDE:-$CANONICAL_REGION}
PRIVATE_IP=$(metadata "vnics/0/privateIp")

mkdir -p "$NOMAD_CONFIG_DIR" "$NOMAD_DATA_DIR"
chmod 0755 "$NOMAD_CONFIG_DIR" "$NOMAD_DATA_DIR"

export OCI_CLI_AUTH=instance_principal

declare -a PEER_IPS=()

discover_peers() {
  local attempt max_attempts sleep_seconds
  attempt=1
  max_attempts=60
  sleep_seconds=10
  while (( attempt <= max_attempts )); do
    PEER_IPS=()
    local peer_ids
    peer_ids=$(oci compute instance list \
      --compartment-id "$COMPARTMENT_OCID" \
      --all 2>/dev/null | jq -r --arg role "$CLUSTER_ROLE" '(.data // [])[] | select((. ["freeform-tags"].ClusterRole // "") == $role and (."lifecycle-state" // "") == "RUNNING") | .id')

    if [[ -n "$peer_ids" ]]; then
      while IFS= read -r peer_id; do
        [[ -z "$peer_id" ]] && continue
        local peer_ip
        peer_ip=$(oci compute instance list-vnics \
          --instance-id "$peer_id" \
          --all 2>/dev/null | jq -r '(.data // [])[] | ."private-ip"' | head -n1)
        [[ -z "$peer_ip" || "$peer_ip" == "null" ]] && continue
        PEER_IPS+=("$peer_ip")
      done <<<"$peer_ids"
    fi

    PEER_IPS+=("$PRIVATE_IP")
    mapfile -t PEER_IPS < <(printf '%s\n' "${PEER_IPS[@]}" | awk 'NF' | sort -u)

    if ((${#PEER_IPS[@]} >= ${CLUSTER_SIZE:-1})); then
      log "Discovered ${#PEER_IPS[@]} Nomad peers (target ${CLUSTER_SIZE})."
      return 0
    fi

    log "Peer discovery attempt ${attempt}/${max_attempts} found ${#PEER_IPS[@]} peers; retrying in ${sleep_seconds}s..."
    sleep "$sleep_seconds"
    attempt=$((attempt + 1))
  done

  log "Peer discovery timed out; continuing with ${#PEER_IPS[@]} peers."
}

discover_peers

RETRY_JOIN_JSON="["
for ip in "${PEER_IPS[@]}"; do
  RETRY_JOIN_JSON+="\"$ip\"," 
done
RETRY_JOIN_JSON="${RETRY_JOIN_JSON%,}]"

cat >"$NOMAD_CONFIG_DIR/server.hcl" <<EOF
name = "${INSTANCE_ID}"
data_dir = "${NOMAD_DATA_DIR}"
region = "${REGION}"
datacenter = "${REGION}"
bind_addr = "0.0.0.0"
advertise {
  http = "${PRIVATE_IP}:4646"
  rpc  = "${PRIVATE_IP}:4647"
  serf = "${PRIVATE_IP}:4648"
}

server {
  enabled          = true
  bootstrap_expect = ${CLUSTER_SIZE}
  retry_join       = ${RETRY_JOIN_JSON}
}

acl {
  enabled = false
}

consul {
  address = "127.0.0.1:8500"
}

telemetry {
  prometheus_metrics = true
}
EOF

chown "$NOMAD_USER:$NOMAD_USER" "$NOMAD_CONFIG_DIR/server.hcl"

cat >"$NOMAD_SERVICE_PATH" <<EOF
[Unit]
Description=HashiCorp Nomad
Documentation=https://www.nomadproject.io/docs/
After=network-online.target consul.service
Wants=network-online.target

[Service]
Type=simple
User=${NOMAD_USER}
Group=${NOMAD_USER}
ExecStart=${NOMAD_BIN_DIR}/nomad agent -config=${NOMAD_CONFIG_DIR}
ExecReload=/bin/kill -HUP \$MAINPID
KillSignal=SIGINT
LimitNOFILE=65536
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable nomad.service
systemctl restart nomad.service

wait_for_nomad_api() {
  for attempt in $(seq 1 120); do
    if curl -sf http://127.0.0.1:4646/v1/status/leader >/dev/null; then
      return 0
    fi
    sleep 2
  done
  return 1
}

if wait_for_nomad_api; then
  log "Nomad HTTP API reachable."
else
  log "Nomad HTTP API did not become ready in time." >&2
fi

log "Nomad server bootstrap complete."
