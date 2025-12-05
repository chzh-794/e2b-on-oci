#!/bin/bash
# E2B on OCI - Complete POC Deployment Script
# This script deploys E2B across 3 OCI instances

set -e
set -o pipefail
set +o history

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/deploy.env"

if [[ -f "${CONFIG_FILE}" ]]; then
  echo "Loading deployment configuration from ${CONFIG_FILE}"
  set -a
  source "${CONFIG_FILE}"
  set +a
else
  echo "Missing ${CONFIG_FILE}. Copy deploy.env.example to deploy.env and fill in your OCI values."
  exit 1
fi

SSH_USER=${SSH_USER:-ubuntu}
SSH_KEY=${SSH_KEY:-$HOME/.ssh/e2b_id_rsa}
SSH_KEY=${SSH_KEY/#\~/$HOME}
POSTGRES_USER=${POSTGRES_USER:-admin}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-E2bP0cPostgres!2025}
POSTGRES_DB=${POSTGRES_DB:-postgres}
POSTGRES_PORT=${POSTGRES_PORT:-5432}

SERVER_POOL_PRIVATE=${SERVER_POOL_PRIVATE:-$SERVER_POOL_PUBLIC}
API_POOL_PRIVATE=${API_POOL_PRIVATE:-$API_POOL_PUBLIC}
CLIENT_POOL_PRIVATE=${CLIENT_POOL_PRIVATE:-$CLIENT_POOL_PUBLIC}

# Always target private IPs via bastion when available
API_TARGET=${API_POOL_PRIVATE:-$API_POOL_PUBLIC}
CLIENT_TARGET=${CLIENT_POOL_PRIVATE:-$CLIENT_POOL_PUBLIC}

REQUIRED_VARS=(
  BASTION_HOST
  SERVER_POOL_PUBLIC
  API_POOL_PUBLIC
  CLIENT_POOL_PUBLIC
  POSTGRES_HOST
)
MISSING_VARS=()
for var in "${REQUIRED_VARS[@]}"; do
  value="${!var}"
  if [[ -z "${value}" ]] || [[ ${value} == REPLACE_* ]]; then
    MISSING_VARS+=("${var}")
  fi
done

if [[ ${#MISSING_VARS[@]} -ne 0 ]]; then
  echo "The following variables are missing or unset: ${MISSING_VARS[*]}"
  echo "Update deploy.env before running this script."
  exit 1
fi

REDIS_ENDPOINT=${REDIS_ENDPOINT:-""}
REDIS_PORT=${REDIS_PORT:-"6379"}
CONSUL_GOSSIP_KEY=${CONSUL_GOSSIP_KEY:-"u1N1pLZm4iM5XOoCFu3Hy7Db2Z7hP6rXH0y0Y9MZ4XI="}
CONSUL_SERVERS_VAR=${CONSUL_SERVERS:-${SERVER_POOL_PRIVATE}}

POSTGRES_CONNECTION_STRING="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}?sslmode=require"

KNOWN_HOSTS_FILE=${KNOWN_HOSTS_FILE:-$HOME/.ssh/known_hosts}
mkdir -p "$(dirname "${KNOWN_HOSTS_FILE}")"
touch "${KNOWN_HOSTS_FILE}"
# Normalize host keys to avoid blocking on rotation
ssh-keygen -R "${SERVER_POOL_PRIVATE}" -f "${KNOWN_HOSTS_FILE}" >/dev/null 2>&1 || true
ssh-keygen -R "${API_POOL_PRIVATE}" -f "${KNOWN_HOSTS_FILE}" >/dev/null 2>&1 || true
ssh-keygen -R "${CLIENT_POOL_PRIVATE}" -f "${KNOWN_HOSTS_FILE}" >/dev/null 2>&1 || true
if [[ -n "${BASTION_HOST}" ]]; then
  ssh-keygen -R "${BASTION_HOST}" -f "${KNOWN_HOSTS_FILE}" >/dev/null 2>&1 || true
  if ! ssh-keygen -F "${BASTION_HOST}" -f "${KNOWN_HOSTS_FILE}" >/dev/null 2>&1; then
    ssh-keyscan -H "${BASTION_HOST}" >> "${KNOWN_HOSTS_FILE}" 2>/dev/null || true
  fi
fi


FIRECRACKER_RELEASE="v1.10.1"
FIRECRACKER_VERSION_FULL="v1.10.1_1fcdaec"
FIRECRACKER_CI_VERSION="v1.10"
FIRECRACKER_KERNEL_VERSION="6.1.102"
FIRECRACKER_KERNEL_PATH="/var/e2b/kernels/vmlinux-${FIRECRACKER_KERNEL_VERSION}/vmlinux.bin"

EDGE_SERVICE_SECRET="E2bEdgeSecret2025!"

SSH_BASE_OPTS=(-i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile="${KNOWN_HOSTS_FILE}" -o IdentitiesOnly=yes)
if [[ -n "${BASTION_HOST}" ]]; then
  # Use ProxyCommand instead of ProxyJump so we can pass -i to the proxy SSH command
  SSH_OPTS=("${SSH_BASE_OPTS[@]}" -o ProxyCommand="ssh -i ${SSH_KEY} -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=${KNOWN_HOSTS_FILE} -W %h:%p ${SSH_USER}@${BASTION_HOST}")
else
  SSH_OPTS=("${SSH_BASE_OPTS[@]}")
fi
SSH_COMMAND="ssh"

ensure_consul_agent() {
  local target_host=$1
  local target_label=$2
  local node_class=$3

  echo -e "\n${YELLOW}Ensuring Consul agent on ${target_label} (${target_host})...${NC}"
  ssh "${SSH_OPTS[@]}" ${SSH_USER}@${target_host} <<EOF
set -e
SERVERS_CSV="${CONSUL_SERVERS_VAR}"
if [[ -z "\$SERVERS_CSV" ]]; then
  echo "CONSUL_SERVERS not set; cannot configure Consul client." >&2
  exit 1
fi

IFS=',' read -ra SERVER_LIST <<< "\$SERVERS_CSV"
SERVER_JSON="["
for ip in "\${SERVER_LIST[@]}"; do
  ip=\$(echo "\$ip" | xargs)
  [[ -z "\$ip" ]] && continue
  SERVER_JSON+="\"\$ip\","
done
SERVER_JSON="\${SERVER_JSON%,}]"

INSTANCE_JSON=\$(curl -sf -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v2/instance/)
CANONICAL_REGION=\$(echo "\$INSTANCE_JSON" | jq -r '.canonicalRegionName // empty')
if [[ -z "\$CANONICAL_REGION" ]] || [[ "\$CANONICAL_REGION" == "null" ]]; then
  CANONICAL_REGION=\$(echo "\$INSTANCE_JSON" | jq -r '.region')
fi
REGION=\${CANONICAL_REGION}
PRIVATE_IP=\$(curl -sf -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v2/vnics/0/privateIp || hostname -I | awk '{print \$1}')
NODE_NAME=\$(hostname)

sudo useradd --system --home /opt/consul --shell /bin/false consul >/dev/null 2>&1 || true
sudo mkdir -p /opt/consul/config /opt/consul/data
sudo chown -R consul:consul /opt/consul

sudo tee /opt/consul/config/client.json >/dev/null <<CONFIG
{
  "server": false,
  "datacenter": "\${REGION}",
  "node_name": "\${NODE_NAME}",
  "advertise_addr": "\${PRIVATE_IP}",
  "bind_addr": "\${PRIVATE_IP}",
  "client_addr": "0.0.0.0",
  "retry_join": \${SERVER_JSON},
  "encrypt": "${CONSUL_GOSSIP_KEY}",
  "acl": {
    "enabled": false
  }
}
CONFIG

sudo tee /etc/systemd/system/consul.service >/dev/null <<'SERVICE'
[Unit]
Description=HashiCorp Consul Client
After=network-online.target
Wants=network-online.target

[Service]
User=consul
Group=consul
ExecStart=/usr/local/bin/consul agent -config-dir=/opt/consul/config -data-dir=/opt/consul/data
ExecReload=/usr/local/bin/consul reload
ExecStop=/usr/local/bin/consul leave
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SERVICE

sudo systemctl daemon-reload
sudo systemctl enable --now consul.service
sudo systemctl status consul --no-pager | head -n 5 || true

# Wait for Consul client to join cluster (up to 60 seconds)
echo "Waiting for Consul client to join cluster..."
MAX_WAIT=60
ELAPSED=0
while [[ \$ELAPSED -lt \$MAX_WAIT ]]; do
  if /usr/local/bin/consul members 2>/dev/null | grep -q "server"; then
    echo "✓ Consul client successfully joined cluster"
    break
  fi
  sleep 2
  ELAPSED=\$((ELAPSED + 2))
done

# If still not connected, restart Consul to retry join
if ! /usr/local/bin/consul members 2>/dev/null | grep -q "server"; then
  echo "⚠ Consul client not connected after \$MAX_WAIT seconds, restarting to retry join..."
  sudo systemctl restart consul.service
  sleep 5
  # Verify again after restart
  if /usr/local/bin/consul members 2>/dev/null | grep -q "server"; then
    echo "✓ Consul client connected after restart"
  else
    echo "⚠ Consul client still not connected - may need manual intervention"
  fi
fi
EOF
  echo "✓ Consul agent ensured on ${target_label}"
}

configure_consul_dns() {
  local target_host=$1
  local target_label=$2

  echo -e "\n${YELLOW}Configuring Consul DNS forwarding on ${target_label} (${target_host})...${NC}"
  ssh "${SSH_OPTS[@]}" ${SSH_USER}@${target_host} <<'EOF'
set -e
sudo mkdir -p /etc/systemd/resolved.conf.d
sudo tee /etc/systemd/resolved.conf.d/consul.conf >/dev/null <<'CONF'
[Resolve]
DNS=127.0.0.1:8600
DNSSEC=false
Domains=~consul
CONF
sudo systemctl restart systemd-resolved
EOF
  echo "✓ Consul DNS forwarding configured on ${target_label}"
}

stage_repo() {
  local target_host=$1
  local target_label=$2

  echo -e "\n${YELLOW}Staging repository on ${target_label} (${target_host})...${NC}"
  tar -C "${SCRIPT_DIR}" \
    --exclude '.git' \
    --exclude 'e2b-oci-stack.zip' \
    --exclude 'e2b-oci-cluster.zip' \
    --exclude 'deploy.env' \
    -czf - . \
    | ssh "${SSH_OPTS[@]}" ${SSH_USER}@${target_host} 'rm -rf ~/e2b && mkdir -p ~/e2b && tar -xzf - -C ~/e2b'
  echo "✓ Repository staged on ${target_label}"
}

ensure_nomad_user() {
  local target_host=$1
  local target_label=$2

  echo -e "\n${YELLOW}Ensuring nomad user exists on ${target_label} (${target_host})...${NC}"
  ssh "${SSH_OPTS[@]}" ${SSH_USER}@${target_host} <<'EOF'
set -e
if ! id -u nomad >/dev/null 2>&1; then
  sudo useradd --system --home /var/lib/nomad --shell /usr/sbin/nologin nomad
fi
sudo mkdir -p /var/lib/nomad
sudo chown -R nomad:nomad /var/lib/nomad
EOF
  echo "✓ Nomad user ensured on ${target_label}"
}

ensure_nomad_agent() {
  local target_host=$1
  local target_label=$2
  local node_class=$3

  echo -e "\n${YELLOW}Ensuring Nomad agent on ${target_label} (${target_host})...${NC}"
  ssh "${SSH_OPTS[@]}" ${SSH_USER}@${target_host} <<EOF
set -e
SERVER_ADDR="${SERVER_POOL_PRIVATE}:4647"
if [[ -z "\$SERVER_ADDR" ]]; then
  echo "SERVER_POOL_PRIVATE is not set; cannot configure Nomad client." >&2
  exit 1
fi

INSTANCE_JSON=\$(curl -sf -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v2/instance/)
CANONICAL_REGION=\$(echo "\$INSTANCE_JSON" | jq -r '.canonicalRegionName // empty')
if [[ -z "\$CANONICAL_REGION" ]] || [[ "\$CANONICAL_REGION" == "null" ]]; then
  CANONICAL_REGION=\$(echo "\$INSTANCE_JSON" | jq -r '.region')
fi
REGION=\${CANONICAL_REGION}
PRIVATE_IP=\$(curl -sf -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v2/vnics/0/privateIp || hostname -I | awk '{print \$1}')
NODE_NAME=\$(hostname)

sudo mkdir -p /opt/nomad/config /opt/nomad/data /var/e2b/templates

# Check existing config before writing to determine if restart is needed
CONFIG_NEEDS_UPDATE=false
if [[ -f /opt/nomad/config/client.hcl ]]; then
  if ! sudo grep -q "no_cgroups = true" /opt/nomad/config/client.hcl 2>/dev/null; then
    CONFIG_NEEDS_UPDATE=true
  fi
  if ! sudo grep -q "node_class = \"${node_class}\"" /opt/nomad/config/client.hcl 2>/dev/null; then
    CONFIG_NEEDS_UPDATE=true
  fi
  # Also check if meta block has node.class
  if ! sudo grep -A 5 "meta {" /opt/nomad/config/client.hcl 2>/dev/null | grep -q "\"node.class\""; then
    CONFIG_NEEDS_UPDATE=true
  fi
else
  CONFIG_NEEDS_UPDATE=true
fi

# Always update client.hcl to ensure it's correct (required for mount operations)
sudo tee /opt/nomad/config/client.hcl >/dev/null <<CONFIG
name       = "\${NODE_NAME}"
data_dir   = "/opt/nomad/data"
region     = "\${REGION}"
datacenter = "\${REGION}"
bind_addr  = "0.0.0.0"

advertise {
  http = "\${PRIVATE_IP}:4646"
  rpc  = "\${PRIVATE_IP}:4647"
  serf = "\${PRIVATE_IP}:4648"
}

client {
  enabled    = true
  node_class = "${node_class}"
  servers    = ["\${SERVER_ADDR}"]

  meta {
    "node.class" = "${node_class}"
  }

  host_volume "e2b-templates" {
    path      = "/var/e2b/templates"
    read_only = false
  }
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
CONFIG

if [[ ! -f /etc/systemd/system/nomad.service ]]; then
  sudo tee /etc/systemd/system/nomad.service >/dev/null <<'SERVICE'
[Unit]
Description=HashiCorp Nomad Client
After=network-online.target cloud-final.service
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/nomad agent -config=/opt/nomad/config
ExecReload=/bin/kill -HUP $MAINPID
KillSignal=SIGINT
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SERVICE
fi

sudo mkdir -p /etc/systemd/system/nomad.service.d
sudo tee /etc/systemd/system/nomad.service.d/10-e2b-devices.conf >/dev/null <<'SERVICE'
[Service]
PrivateDevices=no
SERVICE

sudo systemctl daemon-reload

# Check if Nomad needs restart
NOMAD_RUNNING=false
NEEDS_RESTART=false

# Check if Nomad is currently running
if sudo systemctl is-active --quiet nomad.service; then
  NOMAD_RUNNING=true
fi

# Determine if restart is needed
# Restart if: config was updated OR Nomad is not running
if [[ "$CONFIG_NEEDS_UPDATE" == "true" ]]; then
  NEEDS_RESTART=true
  if [[ "$NOMAD_RUNNING" == "true" ]]; then
    echo "Config updated, will restart Nomad to apply changes"
  else
    echo "Config updated, will start Nomad"
  fi
elif [[ "$NOMAD_RUNNING" == "false" ]]; then
  NEEDS_RESTART=true
  echo "Nomad not running, will start it"
fi

# Only restart if needed
if [[ "$NEEDS_RESTART" == "true" ]]; then
  # Stop Nomad if running (plugin configs are only loaded at startup)
  if [[ "$NOMAD_RUNNING" == "true" ]]; then
    echo "Stopping Nomad to reload plugin configuration..."
    sudo systemctl stop nomad.service
    # Wait for Nomad to fully stop (up to 30 seconds)
    for i in {1..30}; do
      if ! sudo systemctl is-active --quiet nomad.service; then
        break
      fi
      sleep 1
    done
    if sudo systemctl is-active --quiet nomad.service; then
      echo "WARNING: Nomad did not stop gracefully, forcing stop..." >&2
      sudo systemctl kill --kill-who=all nomad.service || true
      sleep 2
    fi
  fi

  # Start Nomad with the new configuration
  sudo systemctl start nomad.service
  sudo systemctl enable nomad.service

  # Wait for Nomad to be fully started (up to 30 seconds)
  for i in {1..30}; do
    if sudo systemctl is-active --quiet nomad.service; then
      # Verify Nomad is responding
      if timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/4646' 2>/dev/null; then
        exec 3<&-
        exec 3>&-
        break
      fi
    fi
    sleep 1
  done

  sudo systemctl status nomad --no-pager | head -n 5 || true
else
  echo "Nomad already running with correct config, skipping restart"
  # Just verify it's responding
  if ! timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/4646' 2>/dev/null; then
    echo "WARNING: Nomad service is active but not responding, restarting..." >&2
    sudo systemctl restart nomad.service
    sleep 5
  fi
fi

# Verify the plugin config was loaded by checking the config file
if ! sudo grep -q "no_cgroups = true" /opt/nomad/config/client.hcl; then
  echo "ERROR: no_cgroups = true not found in Nomad config!" >&2
  exit 1
fi
echo "✓ Verified no_cgroups = true in Nomad config"

# Verify node_class is set in config
if ! sudo grep -q "node_class = \"${node_class}\"" /opt/nomad/config/client.hcl; then
  echo "ERROR: node_class = \"${node_class}\" not found in Nomad config!" >&2
  exit 1
fi
echo "✓ Verified node_class = \"${node_class}\" in Nomad config"

# Verify meta block has node.class
if ! sudo grep -A 5 "meta {" /opt/nomad/config/client.hcl 2>/dev/null | grep -q "\"node.class\""; then
  echo "ERROR: node.class not found in meta block!" >&2
  exit 1
fi
echo "✓ Verified node.class in meta block"

echo 'ubuntu ALL=(ALL) NOPASSWD: /usr/local/bin/nomad' | sudo tee /etc/sudoers.d/99-e2b-nomad >/dev/null
sudo chmod 440 /etc/sudoers.d/99-e2b-nomad
EOF
  echo "✓ Nomad agent ensured on ${target_label}"
}

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

PACKAGES_DIR="${SCRIPT_DIR}/packages"

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║       E2B on OCI - POC Deployment                         ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Deployment Configuration:${NC}"
echo "  Server Pool:  ${SERVER_POOL_PUBLIC} (${SERVER_POOL_PRIVATE})"
echo "  API Pool:     ${API_POOL_PUBLIC} (${API_POOL_PRIVATE})"
echo "  Client Pool:  ${CLIENT_POOL_PUBLIC} (${CLIENT_POOL_PRIVATE})"
echo ""

# Phase 1: Install Dependencies
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Phase 1: Installing Dependencies${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"

ensure_nomad_user ${API_TARGET} "API Pool"
ensure_nomad_user ${CLIENT_TARGET} "Client Pool"

echo -e "\n${YELLOW}[1/3] Server Pool already provisioned via Terraform. Skipping host prep...${NC}"

echo -e "\n${YELLOW}[2/3] Installing dependencies on API Pool...${NC}"
ssh "${SSH_OPTS[@]}" ${SSH_USER}@${API_TARGET} << 'ENDSSH'
set -e
sudo sh -c 'printf "Acquire::ForceIPv4 \"true\";\n" > /etc/apt/apt.conf.d/99force-ipv4'
while sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do sleep 2; done
while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 2; done
sudo apt update
sudo DEBIAN_FRONTEND=noninteractive apt install -y wget curl postgresql-client
if ! command -v psql >/dev/null 2>&1; then
  echo "✗ PostgreSQL client (psql) not found after installation attempt" >&2
  exit 1
fi
echo "✓ PostgreSQL client installed: $(psql --version | head -n1)"

# Install Go
if ! command -v go &> /dev/null; then
    cd /tmp
    wget -q https://go.dev/dl/go1.21.5.linux-amd64.tar.gz
    sudo tar -C /usr/local -xzf go1.21.5.linux-amd64.tar.gz
    echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
    echo "✓ Go installed"
else
    echo "✓ Go already installed"
fi
ENDSSH

echo -e "\n${YELLOW}[3/3] Installing dependencies on Client Pool...${NC}"
ssh "${SSH_OPTS[@]}" ${SSH_USER}@${CLIENT_TARGET} << 'ENDSSH'
set -e
sudo sh -c 'printf "Acquire::ForceIPv4 \"true\";\n" > /etc/apt/apt.conf.d/99force-ipv4'
while sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do sleep 2; done
while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 2; done
sudo apt update
sudo systemctl stop docker docker.socket >/dev/null 2>&1 || true
sudo apt remove -y docker-ce docker-ce-cli docker-buildx-plugin docker-compose-plugin containerd containerd.io >/dev/null 2>&1 || true
sudo DEBIAN_FRONTEND=noninteractive apt install -y wget curl docker.io
sudo systemctl daemon-reload
sudo systemctl enable --now docker.socket
sudo systemctl restart docker || sudo systemctl start docker

# Install Go
if ! command -v go &> /dev/null; then
    cd /tmp
    wget -q https://go.dev/dl/go1.21.5.linux-amd64.tar.gz
    sudo tar -C /usr/local -xzf go1.21.5.linux-amd64.tar.gz
    echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
    echo "✓ Go installed"
else
    echo "✓ Go already installed"
fi

# Mount /run/netns as shared for named network namespace support
# This is required for netns.NewNamed() to work (used by orchestrator for sandbox network isolation)
# /var/run/netns is a symlink to /run/netns
# Make /run shared first, then mount /run/netns as shared tmpfs
sudo mkdir -p /var/run/netns /run/netns
sudo mount --make-shared /run 2>/dev/null || true
sudo umount /run/netns 2>/dev/null || true
sudo mount -t tmpfs -o shared tmpfs /run/netns || true

# Grant CAP_SYS_ADMIN to unshare, bash, ip, losetup, and mount binaries for Firecracker namespace isolation
# This allows nomad user to:
# - Run 'unshare -pf' and perform tmpfs mounts inside the unshare namespace
# - Create network namespaces via Go netns.NewNamed() (which may use ip netns internally)
# - Mount ext4 filesystems via 'mount -o loop' (mount internally uses losetup, so losetup needs CAP_SYS_ADMIN)
sudo setcap cap_sys_admin+ep /usr/bin/unshare || true
sudo setcap cap_sys_admin+ep /usr/bin/bash || true
sudo setcap cap_sys_admin+ep /usr/bin/ip || true
sudo setcap cap_sys_admin+ep /usr/sbin/losetup || true
sudo setcap cap_sys_admin+ep /usr/bin/mount || true

# Add root (Nomad agent user) to disk and kvm groups for NBD device access
# This is required for orchestrator to access /dev/nbd* devices in Nomad raw_exec allocations
# POC fix from POC_SUMMARY.md section "### 5. NBD Device Permissions"
sudo usermod -a -G disk,kvm root || true

# Configure NBD module parameters persistently
sudo mkdir -p /etc/modprobe.d
sudo tee /etc/modprobe.d/nbd.conf >/dev/null <<'EOF'
options nbd max_part=16 nbds_max=128
EOF

# Load NBD kernel module
sudo modprobe -r nbd || true
sudo modprobe nbd
echo "✓ NBD module configured (max_part=16, nbds_max=128)"

# Create template storage directory
sudo mkdir -p /var/e2b/templates
sudo chown -R nomad:nomad /var/e2b
echo "✓ Template storage directory created"

# Disable UFW firewall (OCI default) - it adds REJECT rules that block Firecracker VM traffic
# UFW adds "REJECT all" rules to FORWARD chain which prevents sandbox network connectivity
if command -v ufw >/dev/null 2>&1; then
  sudo ufw disable || true
  sudo systemctl stop ufw || true
  sudo systemctl disable ufw || true
  echo "✓ UFW firewall disabled"
fi

# Configure iptables to allow orchestrator and template-manager gRPC ports
# (POC explicitly uses iptables, not nftables - see POC_SUMMARY.md)
if command -v iptables >/dev/null 2>&1; then
  # Remove any UFW REJECT rules from FORWARD chain that block all traffic
  sudo iptables -D FORWARD -j REJECT --reject-with icmp-host-prohibited 2>/dev/null || true
  
  sudo iptables -I INPUT 1 -p tcp --dport 5008 -s 10.0.0.0/16 -j ACCEPT 2>/dev/null || true
  sudo iptables -I INPUT 1 -p tcp --dport 5009 -s 10.0.0.0/16 -j ACCEPT 2>/dev/null || true
  echo "✓ iptables rules for ports 5008/5009 added"
fi
ENDSSH

echo -e "${GREEN}✓ Phase 1 Complete: All dependencies installed${NC}"

# Stage repo contents on API & Client pools for migrations/configs
stage_repo ${API_TARGET} "API Pool"
stage_repo ${CLIENT_TARGET} "Client Pool"

ensure_nomad_user ${API_TARGET} "API Pool"
ensure_nomad_user ${CLIENT_TARGET} "Client Pool"

echo -e "\n${YELLOW}Ensuring Nomad agents are running...${NC}"
ensure_consul_agent ${API_TARGET} "API Pool" "api"
ensure_consul_agent ${CLIENT_TARGET} "Client Pool" "client"
configure_consul_dns ${API_TARGET} "API Pool"
configure_consul_dns ${CLIENT_TARGET} "Client Pool"
ensure_nomad_agent ${API_TARGET} "API Pool" "api"
ensure_nomad_agent ${CLIENT_TARGET} "Client Pool" "client"

# Phase 1b: Install Firecracker and Kernels
echo -e "\n${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Phase 1b: Installing Firecracker ${FIRECRACKER_RELEASE} and kernel ${FIRECRACKER_KERNEL_VERSION}${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"

install_firecracker() {
  local target_host=$1
  local target_label=$2

  echo -e "\n${YELLOW}Installing Firecracker on ${target_label} (${target_host})...${NC}"
  ssh "${SSH_OPTS[@]}" ${SSH_USER}@${target_host} <<EOF
set -e
FIRECRACKER_RELEASE="${FIRECRACKER_RELEASE}"
FIRECRACKER_VERSION="${FIRECRACKER_VERSION_FULL}"
CI_VERSION="${FIRECRACKER_CI_VERSION}"
KERNEL_VERSION="${FIRECRACKER_KERNEL_VERSION}"
TMP_DIR=\$(mktemp -d)
cd \$TMP_DIR

sudo rm -f /usr/local/bin/firecracker
curl -sSL https://github.com/firecracker-microvm/firecracker/releases/download/\${FIRECRACKER_RELEASE}/firecracker-\${FIRECRACKER_RELEASE}-x86_64.tgz | tar -xz
sudo mv release-\${FIRECRACKER_RELEASE}-x86_64/firecracker-\${FIRECRACKER_RELEASE}-x86_64 /usr/local/bin/firecracker
sudo chmod +x /usr/local/bin/firecracker
rm -rf release-\${FIRECRACKER_RELEASE}-x86_64

curl -sSL https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/\${CI_VERSION}/x86_64/vmlinux-\${KERNEL_VERSION} -o vmlinux.bin
sudo mkdir -p /var/e2b/kernels/vmlinux-\${KERNEL_VERSION}
sudo mv vmlinux.bin /var/e2b/kernels/vmlinux-\${KERNEL_VERSION}/vmlinux.bin
sudo chown -R nomad:nomad /var/e2b/kernels

sudo mkdir -p /fc-versions/\${FIRECRACKER_VERSION}
sudo install -m 0755 /usr/local/bin/firecracker /fc-versions/\${FIRECRACKER_VERSION}/firecracker

sudo mkdir -p /fc-kernels/\${KERNEL_VERSION} /fc-kernels/vmlinux-\${KERNEL_VERSION}
sudo install -m 0644 /var/e2b/kernels/vmlinux-\${KERNEL_VERSION}/vmlinux.bin /fc-kernels/\${KERNEL_VERSION}/vmlinux.bin
sudo ln -sf /var/e2b/kernels/vmlinux-\${KERNEL_VERSION}/vmlinux.bin /fc-kernels/vmlinux-\${KERNEL_VERSION}/vmlinux.bin

sudo mkdir -p /mnt/disks/fc-envs/v1
sudo chown -R nomad:nomad /fc-kernels /fc-versions /mnt/disks/fc-envs || true

rm -rf \$TMP_DIR
EOF
  echo "✓ Firecracker installed on ${target_label}"
}

install_firecracker ${API_TARGET} "API Pool"
install_firecracker ${CLIENT_TARGET} "Client Pool"

# Phase 1c: Run database migrations
echo -e "\n${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Phase 1c: Running database migrations${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"

if ssh "${SSH_OPTS[@]}" ${SSH_USER}@${API_TARGET} <<EOF
set -e
set +o history
export POSTGRES_CONNECTION_STRING='${POSTGRES_CONNECTION_STRING}'
cd ~/e2b/packages/db
echo "Starting migrations..."
export PATH=\$PATH:/usr/local/go/bin
go run ./scripts/migrator.go up
EOF
then
  echo "✓ Database migrations applied"
else
  echo -e "${YELLOW}⚠ Database migrations failed. Verify PostgreSQL credentials before proceeding.${NC}"
fi

# Phase 1d: Initialize database (seed users, teams, clusters)
echo -e "\n${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Phase 1d: Initializing database${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"

if "${SCRIPT_DIR}/scripts/run-init-db.sh"; then
  echo "✓ Database initialized with users, teams, and cluster configuration"
else
  echo -e "${RED}✗ Database initialization failed.${NC}"
  echo -e "${RED}  This is a critical step - database must be seeded before services can run.${NC}"
  echo -e "${RED}  Check the error messages above and fix the issue before proceeding.${NC}"
  exit 1
fi

# Phase 2: Build Binaries on Instances
echo -e "\n${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Phase 2: Building Binaries on Instances${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"

echo -e "\n${YELLOW}Building API and Client Proxy on API pool...${NC}"
ssh "${SSH_OPTS[@]}" ${SSH_USER}@${API_TARGET} << 'ENDSSH'
set -e
export PATH=$PATH:/usr/local/go/bin
cd ~/e2b/packages

# Build to ~/e2b/bin so Phase 4 rsync preserves them
mkdir -p ~/e2b/bin

echo "Building API..."
cd api
go build -o ~/e2b/bin/e2b-api .
echo "✓ API built"

echo "Building Client Proxy..."
cd ../client-proxy
go build -o ~/e2b/bin/client-proxy .
echo "✓ Client Proxy built"

# Make binaries executable
chmod +x ~/e2b/bin/*
ENDSSH
echo "✓ API and Client Proxy built on API pool"

echo -e "\n${YELLOW}Building Orchestrator and Template Manager on Client pool...${NC}"
ssh "${SSH_OPTS[@]}" ${SSH_USER}@${CLIENT_TARGET} << 'ENDSSH'
set -e
export PATH=$PATH:/usr/local/go/bin
cd ~/e2b/packages

# Build to ~/e2b/bin so Phase 4 rsync preserves them
mkdir -p ~/e2b/bin

echo "Building Orchestrator..."
cd orchestrator
go build -o ~/e2b/bin/orchestrator .
echo "✓ Orchestrator built"

echo "Building Template Manager (copy of orchestrator)..."
cp ~/e2b/bin/orchestrator ~/e2b/bin/template-manager
echo "✓ Template Manager built"

echo "Building envd..."
cd ../envd

# Ensure Go modules are downloaded
echo "Downloading Go dependencies for envd..."
if ! go mod download 2>&1; then
  echo "WARNING: go mod download failed, continuing anyway..." >&2
fi

# Capture build output for debugging
echo "Running go build..."
BUILD_OUTPUT=$(go build -o ~/e2b/bin/envd . 2>&1)
BUILD_EXIT=$?

if [[ $BUILD_EXIT -ne 0 ]]; then
  echo "ERROR: envd build failed with exit code $BUILD_EXIT" >&2
  echo "Build output:" >&2
  echo "$BUILD_OUTPUT" >&2
  exit 1
fi

# Verify envd binary was created
if [[ ! -f ~/e2b/bin/envd ]]; then
  echo "ERROR: envd binary not found after build!" >&2
  echo "Build output was:" >&2
  echo "$BUILD_OUTPUT" >&2
  echo "Current directory: $(pwd)" >&2
  echo "Files in envd directory:" >&2
  ls -la . >&2 || true
  exit 1
fi

# Verify it's actually executable
if [[ ! -x ~/e2b/bin/envd ]]; then
  echo "WARNING: envd binary exists but is not executable, fixing permissions..." >&2
  chmod +x ~/e2b/bin/envd
fi

echo "✓ envd built ($(du -h ~/e2b/bin/envd | cut -f1))"

# Make all binaries executable
chmod +x ~/e2b/bin/*

# Verify all binaries exist before listing
echo ""
echo "Verifying all binaries exist..."
for bin in orchestrator template-manager envd; do
  if [[ ! -f ~/e2b/bin/$bin ]]; then
    echo "ERROR: ~/e2b/bin/$bin not found!" >&2
    exit 1
  fi
done

# List contents of ~/e2b/bin for debugging
echo ""
echo "Contents of ~/e2b/bin:"
ls -lah ~/e2b/bin/

# Verify binaries were built with correct timestamps
echo ""
echo "Binary timestamps:"
ls -lh ~/e2b/bin/orchestrator ~/e2b/bin/template-manager ~/e2b/bin/envd | awk '{print $6, $7, $8, $9}'
ENDSSH
echo "✓ Orchestrator, Template Manager, and envd built on Client pool"

echo -e "${GREEN}✓ Phase 2 Complete: Binaries built on instances${NC}"

# Phase 3: Create Configuration Files
echo -e "\n${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Phase 3: Creating Configuration Files${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"

echo -e "\n${YELLOW}Creating API service configuration...${NC}"
cat <<EOF | ssh "${SSH_OPTS[@]}" ${SSH_USER}@${API_TARGET} 'cat > ~/e2b/api.env'
# PostgreSQL Configuration (OCI Database)
POSTGRES_CONNECTION_STRING=postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}?sslmode=require

# Storage Configuration (Local for POC)
STORAGE_PROVIDER=Local
LOCAL_TEMPLATE_STORAGE_BASE_PATH=/var/e2b/templates

# Redis Configuration (optional single-node fallback)
# Leave empty to rely on the in-memory sandbox catalog.
REDIS_URL=

# Service Configuration
PORT=50001
LOG_LEVEL=debug

# Sandbox Access Tokens
SANDBOX_ACCESS_TOKEN_HASH_SEED=E2bSandboxSeed2025!

# Template Manager
TEMPLATE_MANAGER_HOST=template-manager.service.consul:5009

# Orchestrator Configuration
ORCHESTRATOR_PORT=5008

# Consul Configuration
CONSUL_URL=http://localhost:8500

# Cloud Provider
CLOUD_PROVIDER=oci
EOF
ssh "${SSH_OPTS[@]}" ${SSH_USER}@${API_TARGET} 'echo "✓ API configuration created"'

echo -e "\n${YELLOW}Creating Client Proxy configuration...${NC}"
cat <<EOF | ssh "${SSH_OPTS[@]}" ${SSH_USER}@${API_TARGET} 'cat > ~/e2b/client-proxy.env'
# Service Configuration
PORT=3001
LOG_LEVEL=debug
EDGE_PORT=3001
PROXY_PORT=3002
ORCHESTRATOR_PORT=5008

# Consul Configuration
CONSUL_URL=http://localhost:8500

# Redis Configuration (optional single-node fallback)
# Leave empty to rely on the in-memory sandbox catalog.
REDIS_URL=
EDGE_SECRET=${EDGE_SERVICE_SECRET}

# Service Discovery
SERVICE_DISCOVERY_ORCHESTRATOR_PROVIDER=DNS
SERVICE_DISCOVERY_ORCHESTRATOR_DNS_RESOLVER_ADDRESS=127.0.0.1:8600
SERVICE_DISCOVERY_ORCHESTRATOR_DNS_QUERY=orchestrator.service.consul,template-manager.service.consul
SERVICE_DISCOVERY_EDGE_PROVIDER=DNS
SERVICE_DISCOVERY_EDGE_DNS_RESOLVER_ADDRESS=127.0.0.1:8600
SERVICE_DISCOVERY_EDGE_DNS_QUERY=edge-api.service.consul

# Observability
OTEL_COLLECTOR_GRPC_ENDPOINT=localhost:4317
LOGS_COLLECTOR_ADDRESS=http://localhost:30006
USE_CATALOG_RESOLUTION=true
LOKI_URL=http://loki.service.consul:3100

# Environment
ENVIRONMENT=dev
CLOUD_PROVIDER=oci
EOF
ssh "${SSH_OPTS[@]}" ${SSH_USER}@${API_TARGET} 'echo "✓ Client Proxy configuration created"'

echo -e "\n${YELLOW}Creating Orchestrator configuration...${NC}"
cat <<EOF | ssh "${SSH_OPTS[@]}" ${SSH_USER}@${CLIENT_TARGET} 'cat > ~/e2b/orchestrator.env'
# Storage Configuration (Local for POC)
STORAGE_PROVIDER=Local
LOCAL_TEMPLATE_STORAGE_BASE_PATH=/var/e2b/templates

# Firecracker Configuration
FIRECRACKER_BIN_PATH=/usr/local/bin/firecracker
KERNEL_PATH=${FIRECRACKER_KERNEL_PATH}
FIRECRACKER_VERSION=${FIRECRACKER_VERSION_FULL}

# NBD Configuration
NBD_POOL_SIZE=100

# Service Configuration
GRPC_PORT=5008
LOG_LEVEL=debug

# Consul Configuration
CONSUL_URL=http://localhost:8500

# Consul Token (placeholder until ACLs enabled)
CONSUL_TOKEN=insecure-placeholder

# Lock Path
ORCHESTRATOR_LOCK_PATH=/opt/e2b/runtime/orchestrator.lock

# Cloud Provider
CLOUD_PROVIDER=oci

# Allow Sandbox Internet
ALLOW_SANDBOX_INTERNET=true
EOF
ssh "${SSH_OPTS[@]}" ${SSH_USER}@${CLIENT_TARGET} 'echo "✓ Orchestrator configuration created"'

echo -e "\n${YELLOW}Creating Template Manager configuration...${NC}"
cat <<EOF | ssh "${SSH_OPTS[@]}" ${SSH_USER}@${CLIENT_TARGET} 'cat > ~/e2b/template-manager.env'
# Storage Configuration (Local for POC)
STORAGE_PROVIDER=Local
LOCAL_TEMPLATE_STORAGE_BASE_PATH=/var/e2b/templates
TEMPLATE_BUCKET_NAME=local

# Artifacts Registry Configuration (Local for POC)
# ARTIFACTS_REGISTRY_PROVIDER=Local

# Artifacts Registry Configuration (OCI OCIR)
ARTIFACTS_REGISTRY_PROVIDER=${ARTIFACTS_REGISTRY_PROVIDER}
OCIR_TEMPLATE_REPOSITORY_PATH=${OCIR_TEMPLATE_REPOSITORY_PATH}
OCI_REGION=${OCI_REGION}
OCIR_NAMESPACE=${OCIR_NAMESPACE}

# OCIR auth (these envs already set on the bastion host via deploy.env)
OCIR_USERNAME=${OCIR_USERNAME}
OCIR_PASSWORD=${OCIR_PASSWORD}

# Firecracker Configuration
FIRECRACKER_BIN_PATH=/usr/local/bin/firecracker
KERNEL_PATH=${FIRECRACKER_KERNEL_PATH}
FIRECRACKER_VERSION=${FIRECRACKER_VERSION_FULL}

# Network
GRPC_PORT=5009
PROXY_PORT=15007

# Service Configuration
LOG_LEVEL=debug
CLOUD_PROVIDER=oci
ENVIRONMENT=dev
OTEL_TRACING_PRINT=false
OTEL_COLLECTOR_GRPC_ENDPOINT=localhost:4317
ORCHESTRATOR_SERVICES=template-manager
SANDBOX_DEBUG_VM_LOGS=true

# Lock Path
ORCHESTRATOR_LOCK_PATH=/opt/e2b/runtime/orchestrator.lock

# Consul/DNS-based service discovery for orchestrator
CONSUL_URL=http://localhost:8500
SERVICE_DISCOVERY_ORCHESTRATOR_PROVIDER=DNS
SERVICE_DISCOVERY_ORCHESTRATOR_DNS_RESOLVER_ADDRESS=127.0.0.1:8600
SERVICE_DISCOVERY_ORCHESTRATOR_DNS_QUERY=orchestrator.service.consul

EOF
ssh "${SSH_OPTS[@]}" ${SSH_USER}@${CLIENT_TARGET} 'echo "✓ Template Manager configuration created"'

echo -e "${GREEN}✓ Phase 3 Complete: Configuration files created${NC}"

# Phase 4: Promote artifacts to /opt/e2b for Nomad runtime
echo -e "\n${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Phase 4: Promoting artifacts to /opt/e2b${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"

echo -e "\n${YELLOW}Syncing API payload to /opt/e2b...${NC}"
ssh "${SSH_OPTS[@]}" ${SSH_USER}@${API_TARGET} <<'ENDSSH'
set -e
sudo mkdir -p /opt/e2b
sudo rsync -a --delete ~/e2b/ /opt/e2b/
sudo mkdir -p /opt/e2b/runtime /opt/e2b/tmp
sudo chown -R nomad:nomad /opt/e2b
sudo chmod -R 755 /opt/e2b
ENDSSH
echo "✓ API payload ready under /opt/e2b"

echo -e "\n${YELLOW}Syncing Client payload to /opt/e2b...${NC}"
ssh "${SSH_OPTS[@]}" ${SSH_USER}@${CLIENT_TARGET} <<'ENDSSH'
set -e
sudo mkdir -p /opt/e2b
sudo rsync -a --delete ~/e2b/ /opt/e2b/
sudo mkdir -p /opt/e2b/runtime /opt/e2b/tmp
sudo chown -R nomad:nomad /opt/e2b
sudo chmod -R 755 /opt/e2b
ENDSSH
echo "✓ Client payload ready under /opt/e2b"

echo -e "${GREEN}✓ Phase 4 Complete: Runtime artifacts promoted${NC}"

# Phase 5: Prepare Template Runtime Assets
echo -e "\n${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Phase 5: Preparing Template Runtime Assets${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"

ssh "${SSH_OPTS[@]}" ${SSH_USER}@${CLIENT_TARGET} <<EOF
set -e
FIRECRACKER_VERSION="${FIRECRACKER_VERSION_FULL}"
KERNEL_VERSION="${FIRECRACKER_KERNEL_VERSION}"
sudo mkdir -p /fc-envd /fc-versions/\${FIRECRACKER_VERSION} /fc-kernels/\${KERNEL_VERSION} /fc-kernels/vmlinux-\${KERNEL_VERSION} /mnt/disks/fc-envs/v1 /orchestrator/sandbox

# Verify envd binary exists before copying
if [[ ! -f /opt/e2b/bin/envd ]]; then
  echo "ERROR: /opt/e2b/bin/envd not found! Build must have failed in Phase 2." >&2
  echo "Please check the Phase 2 build logs above." >&2
  exit 1
fi

if [ ! -e /fc-envd/envd ] || [ ! -L /fc-envd/envd ]; then
  sudo cp /opt/e2b/bin/envd /fc-envd/envd
  sudo chmod 0755 /fc-envd/envd
fi
sudo ln -sf /usr/local/bin/firecracker /fc-versions/\${FIRECRACKER_VERSION}/firecracker
sudo ln -sf /var/e2b/kernels/vmlinux-\${KERNEL_VERSION}/vmlinux.bin /fc-kernels/\${KERNEL_VERSION}/vmlinux.bin
sudo ln -sf /var/e2b/kernels/vmlinux-\${KERNEL_VERSION}/vmlinux.bin /fc-kernels/vmlinux-\${KERNEL_VERSION}/vmlinux.bin
sudo chown -R nomad:nomad /fc-envd /fc-versions /fc-kernels /mnt/disks/fc-envs /orchestrator || true
EOF
echo "✓ Template runtime assets prepared on Client pool"

# Summary
echo -e "\n${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║       Deployment Complete!                                ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}✓ All services deployed and configured${NC}"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo "1. Configure Nomad/Consul cluster (servers and clients)"
echo "2. Load template Docker images per build (see seed-template-image.sh) before triggering template-manager builds"
echo "3. Start the services"
echo ""
echo -e "${YELLOW}To start services manually:${NC}"
echo ""
echo -e "  ${BLUE}On API Pool (${API_TARGET}):${NC}"
echo "    cd /opt/e2b && source api.env && ./bin/e2b-api"
echo "    cd /opt/e2b && source client-proxy.env && ./bin/client-proxy"
echo ""
echo -e "  ${BLUE}On Client Pool (${CLIENT_TARGET}):${NC}"
echo "    cd /opt/e2b && source orchestrator.env && ./bin/orchestrator"
echo "    cd /opt/e2b && source template-manager.env && ./bin/template-manager"
echo ""
echo -e "${YELLOW}OCI Managed Services:${NC}"
echo "  PostgreSQL: ${POSTGRES_HOST}:${POSTGRES_PORT}"
echo "    Database: ${POSTGRES_DB}"
echo "    User: ${POSTGRES_USER}"
echo "    Password: ${POSTGRES_PASSWORD}"
echo ""
echo "  Redis: ${REDIS_ENDPOINT}:${REDIS_PORT}"
echo ""


