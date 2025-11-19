#!/bin/bash

set -euo pipefail

log() {
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "${timestamp} [consul-client] $*"
}

CONSUL_BIN_DIR="/opt/consul/bin"
CONSUL_CONFIG_DIR="/opt/consul/config"
CONSUL_DATA_DIR="/opt/consul/data"
CONSUL_USER="consul"
CONSUL_SERVICE_PATH="/etc/systemd/system/consul.service"

GOSSIP_KEY=""
COMPARTMENT_OCID=""
REGION_OVERRIDE=""
SERVER_ROLE="server"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gossip-encryption-key)
      GOSSIP_KEY="$2"
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

normalize_region() {
  local value="$1"
  case "$value" in
    iad|IAD)
      echo "us-ashburn-1"
      ;;
    phx|PHX)
      echo "us-phoenix-1"
      ;;
    fra|FRA)
      echo "eu-frankfurt-1"
      ;;
    *)
      echo "$value"
      ;;
  esac
}

REGION=$(normalize_region "$REGION")
PRIVATE_IP=$(metadata "vnics/0/privateIp")

rm -rf "$CONSUL_DATA_DIR"
mkdir -p "$CONSUL_CONFIG_DIR" "$CONSUL_DATA_DIR"
chown -R "$CONSUL_USER:$CONSUL_USER" "$CONSUL_CONFIG_DIR" "$CONSUL_DATA_DIR"

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
  RETRY_JOIN_JSON="[]"
else
  RETRY_JOIN_JSON="["
  for ip in "${SERVER_IPS[@]}"; do
    RETRY_JOIN_JSON+="\"$ip\"," 
  done
  RETRY_JOIN_JSON="${RETRY_JOIN_JSON%,}]"
fi

if [[ -n "$GOSSIP_KEY" ]]; then
  ENCRYPT_LINE="  \"encrypt\": \"${GOSSIP_KEY}\","
else
  ENCRYPT_LINE=""
fi

cat >"$CONSUL_CONFIG_DIR/client.json" <<EOF
{
  "server": false,
  "datacenter": "${REGION}",
  "node_name": "${INSTANCE_ID}",
  "advertise_addr": "${PRIVATE_IP}",
  "bind_addr": "${PRIVATE_IP}",
  "client_addr": "0.0.0.0",
  "retry_join": ${RETRY_JOIN_JSON},
${ENCRYPT_LINE}
  "ui": false,
  "acl": {
    "enabled": false
  }
}
EOF

chown "$CONSUL_USER:$CONSUL_USER" "$CONSUL_CONFIG_DIR/client.json"

cat >"$CONSUL_SERVICE_PATH" <<EOF
[Unit]
Description=HashiCorp Consul Client
Documentation=https://www.consul.io/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${CONSUL_USER}
Group=${CONSUL_USER}
ExecStart=${CONSUL_BIN_DIR}/consul agent -config-dir=${CONSUL_CONFIG_DIR} -data-dir=${CONSUL_DATA_DIR}
ExecReload=${CONSUL_BIN_DIR}/consul reload
ExecStop=${CONSUL_BIN_DIR}/consul leave
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable consul.service
systemctl restart consul.service

log "Consul client started and attempting to join servers."
