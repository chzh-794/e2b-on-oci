#!/bin/bash

set -euo pipefail

log() {
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "${timestamp} [nomad-client] $*"
}

NOMAD_BIN_DIR="/opt/nomad/bin"
NOMAD_CONFIG_DIR="/opt/nomad/config"
NOMAD_DATA_DIR="/opt/nomad/data"
NOMAD_USER="root"
NOMAD_SERVICE_PATH="/etc/systemd/system/nomad.service"

NODE_CLASS="client"
COMPARTMENT_OCID=""
REGION_OVERRIDE=""
SERVER_ROLE="server"
EXTRA_META=""
ENABLE_HOST_VOLUME=false
HOST_VOLUME_NAME="e2b-templates"
HOST_VOLUME_PATH="/var/e2b/templates"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --node-class)
      NODE_CLASS="$2"
      shift 2
      ;;
    --compartment-id)
      COMPARTMENT_OCID="$2"
      shift 2
      ;;
    --region)
      REGION_OVERRIDE="$2"
      shift 2
      ;;
    --server-role)
      SERVER_ROLE="$2"
      shift 2
      ;;
    --meta)
      EXTRA_META="$2"
      shift 2
      ;;
    --host-volume)
      ENABLE_HOST_VOLUME=true
      HOST_VOLUME_PATH="$2"
      shift 2
      ;;
    --host-volume-name)
      HOST_VOLUME_NAME="$2"
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
REGION=$(echo "$INSTANCE_JSON" | jq -r '.region')
REGION=${REGION_OVERRIDE:-$REGION}
PRIVATE_IP=$(metadata "vnics/0/privateIp")

mkdir -p "$NOMAD_CONFIG_DIR" "$NOMAD_DATA_DIR"
chown -R "$NOMAD_USER:$NOMAD_USER" "$NOMAD_CONFIG_DIR" "$NOMAD_DATA_DIR"

if [[ "$ENABLE_HOST_VOLUME" == true ]]; then
  sudo mkdir -p "$HOST_VOLUME_PATH"
  sudo chmod 0775 "$HOST_VOLUME_PATH"
fi

export OCI_CLI_AUTH=instance_principal

declare -a SERVER_IPS=()

fetch_server_ips() {
  SERVER_IPS=()
  local peer_ids
  peer_ids=$(oci compute instance list \
    --compartment-id "$COMPARTMENT_OCID" \
    --all 2>/dev/null | jq -r --arg role "$SERVER_ROLE" '(.data // [])[] | select((. ["freeform-tags"].ClusterRole // "") == $role and (."lifecycle-state" // "") == "RUNNING") | .id')

  if [[ -n "$peer_ids" ]]; then
    while IFS= read -r peer_id; do
      [[ -z "$peer_id" ]] && continue
      local peer_ip
      peer_ip=$(oci compute instance list-vnics \
        --instance-id "$peer_id" \
        --all 2>/dev/null | jq -r '(.data // [])[] | ."private-ip"' | head -n1)
      [[ -z "$peer_ip" || "$peer_ip" == "null" ]] && continue
      SERVER_IPS+=("$peer_ip")
    done <<<"$peer_ids"
  fi
}

fetch_server_ips

if ((${#SERVER_IPS[@]} == 0)); then
  SERVER_JSON="[]"
else
  SERVER_JSON="["
  for ip in "${SERVER_IPS[@]}"; do
    SERVER_JSON+="\"${ip}:4647\"," 
  done
  SERVER_JSON="${SERVER_JSON%,}]"
fi

cat >"$NOMAD_CONFIG_DIR/client.hcl" <<EOF
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

client {
  enabled    = true
  node_class = "${NODE_CLASS}"
  servers    = ${SERVER_JSON}
EOF

if [[ -n "$EXTRA_META" ]]; then
  cat >>"$NOMAD_CONFIG_DIR/client.hcl" <<EOF

  meta {
    ${EXTRA_META}
  }
EOF
fi

if [[ "$ENABLE_HOST_VOLUME" == true ]]; then
  cat >>"$NOMAD_CONFIG_DIR/client.hcl" <<EOF

  host_volume "${HOST_VOLUME_NAME}" {
    path      = "${HOST_VOLUME_PATH}"
    read_only = false
  }
EOF
fi

cat >>"$NOMAD_CONFIG_DIR/client.hcl" <<'EOF'
}

plugin "raw_exec" {
  config {
    enabled = true
    no_cgroups = true
  }
}

consul {
  address = "127.0.0.1:8500"
}

telemetry {
  prometheus_metrics = true
}
EOF

# ensure the closing brace placement
# shellcheck disable=SC1004
sed -i 's/}\n$/}/' "$NOMAD_CONFIG_DIR/client.hcl"

chown "$NOMAD_USER:$NOMAD_USER" "$NOMAD_CONFIG_DIR/client.hcl"

cat >"$NOMAD_SERVICE_PATH" <<EOF
[Unit]
Description=HashiCorp Nomad Client
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

log "Nomad client started and attempting to connect to servers."
