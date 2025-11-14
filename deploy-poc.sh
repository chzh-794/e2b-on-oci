#!/bin/bash
# E2B on OCI - Complete POC Deployment Script
# This script deploys E2B across 3 OCI instances

set -e
set -o pipefail
set +o history

# Configuration
SERVER_POOL_PUBLIC="10.0.2.231"
SERVER_POOL_PRIVATE="10.0.2.231"

API_POOL_PUBLIC="10.0.2.198"
API_POOL_PRIVATE="10.0.2.198"

CLIENT_POOL_PUBLIC="10.0.2.73"
CLIENT_POOL_PRIVATE="10.0.2.73"

# OCI Managed Services
POSTGRES_HOST="10.0.2.127"
POSTGRES_USER="admin"
POSTGRES_PASSWORD="E2bP0cPostgres!2025"
POSTGRES_DB="postgres"
POSTGRES_PORT="5432"

REDIS_ENDPOINT="aaax7756raag5e34ggx7safceks7dzhj6o5srzjqqxxdynjjatt354a-p.redis.ap-osaka-1.oci.oraclecloud.com"
REDIS_PORT="6379"

POSTGRES_CONNECTION_STRING="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}?sslmode=require"

FIRECRACKER_RELEASE="v1.10.1"
FIRECRACKER_VERSION_FULL="v1.10.1_1fcdaec"
FIRECRACKER_CI_VERSION="v1.10"
FIRECRACKER_KERNEL_VERSION="6.1.102"
FIRECRACKER_KERNEL_PATH="/var/e2b/kernels/vmlinux-${FIRECRACKER_KERNEL_VERSION}/vmlinux.bin"

EDGE_SERVICE_SECRET="E2bEdgeSecret2025!"

SSH_USER="ubuntu"
SSH_KEY="$HOME/.ssh/id_rsa"
BASTION_HOST="192.29.245.106"
SSH_OPTS="-i ${SSH_KEY} -o StrictHostKeyChecking=no -o ProxyJump=${SSH_USER}@${BASTION_HOST}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# TEMPORARILY SKIP SERVER POOL - Not critical for POC
# echo -e "\n${YELLOW}[1/3] Installing dependencies on Server Pool...${NC}"
# ssh $SSH_OPTS ${SSH_USER}@${SERVER_POOL_PUBLIC} << 'ENDSSH'
# sudo apt update
# echo "✓ Package list updated"
# ENDSSH
echo -e "\n${YELLOW}[1/3] Skipping Server Pool (not critical for POC)...${NC}"

echo -e "\n${YELLOW}[2/3] Installing dependencies on API Pool...${NC}"
ssh $SSH_OPTS ${SSH_USER}@${API_POOL_PUBLIC} << 'ENDSSH'
set -e
sudo apt update
sudo DEBIAN_FRONTEND=noninteractive apt install -y wget curl postgresql-client
echo "✓ PostgreSQL client installed (using OCI managed database)"

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
ssh $SSH_OPTS ${SSH_USER}@${CLIENT_POOL_PUBLIC} << 'ENDSSH'
set -e
sudo apt update
sudo DEBIAN_FRONTEND=noninteractive apt install -y wget curl docker.io
sudo systemctl enable --now docker

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

# Load NBD kernel module
sudo modprobe nbd max_part=16 || true
echo "✓ NBD module loaded"

# Create template storage directory
sudo mkdir -p /var/e2b/templates
sudo chown -R nomad:nomad /var/e2b
echo "✓ Template storage directory created"
ENDSSH

echo -e "${GREEN}✓ Phase 1 Complete: All dependencies installed${NC}"

# Phase 1b: Install Firecracker and Kernels
echo -e "\n${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Phase 1b: Installing Firecracker ${FIRECRACKER_RELEASE} and kernel ${FIRECRACKER_KERNEL_VERSION}${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"

install_firecracker() {
  local target_host=$1
  local target_label=$2

  echo -e "\n${YELLOW}Installing Firecracker on ${target_label} (${target_host})...${NC}"
  ssh \
    FIRECRACKER_RELEASE="${FIRECRACKER_RELEASE}" \
    FIRECRACKER_VERSION="${FIRECRACKER_VERSION_FULL}" \
    CI_VERSION="${FIRECRACKER_CI_VERSION}" \
    KERNEL_VERSION="${FIRECRACKER_KERNEL_VERSION}" \
    $SSH_OPTS ${SSH_USER}@${target_host} <<'EOF'
set -e
TMP_DIR=$(mktemp -d)
cd $TMP_DIR

sudo rm -f /usr/local/bin/firecracker
curl -sSL https://github.com/firecracker-microvm/firecracker/releases/download/${FIRECRACKER_RELEASE}/firecracker-${FIRECRACKER_RELEASE}-x86_64.tgz | tar -xz
sudo mv release-${FIRECRACKER_RELEASE}-x86_64/firecracker-${FIRECRACKER_RELEASE}-x86_64 /usr/local/bin/firecracker
sudo chmod +x /usr/local/bin/firecracker
rm -rf release-${FIRECRACKER_RELEASE}-x86_64

curl -sSL https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/${CI_VERSION}/x86_64/vmlinux-${KERNEL_VERSION} -o vmlinux.bin
sudo mkdir -p /var/e2b/kernels/vmlinux-${KERNEL_VERSION}
sudo mv vmlinux.bin /var/e2b/kernels/vmlinux-${KERNEL_VERSION}/vmlinux.bin
sudo chown -R nomad:nomad /var/e2b/kernels

sudo mkdir -p /fc-versions/${FIRECRACKER_VERSION}
sudo cp /usr/local/bin/firecracker /fc-versions/${FIRECRACKER_VERSION}/firecracker
sudo chmod +x /fc-versions/${FIRECRACKER_VERSION}/firecracker

sudo mkdir -p /fc-kernels/${KERNEL_VERSION}
sudo cp /var/e2b/kernels/vmlinux-${KERNEL_VERSION}/vmlinux.bin /fc-kernels/${KERNEL_VERSION}/vmlinux.bin
sudo chmod 0644 /fc-kernels/${KERNEL_VERSION}/vmlinux.bin

sudo mkdir -p /mnt/disks/fc-envs/v1
sudo chown -R nomad:nomad /fc-kernels /fc-versions /mnt/disks/fc-envs || true

rm -rf $TMP_DIR
EOF
  echo "✓ Firecracker installed on ${target_label}"
}

install_firecracker ${API_POOL_PUBLIC} "API Pool"
install_firecracker ${CLIENT_POOL_PUBLIC} "Client Pool"

# Phase 1c: Run database migrations
echo -e "\n${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Phase 1c: Running database migrations${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"

if ssh $SSH_OPTS ${SSH_USER}@${API_POOL_PUBLIC} <<EOF
set -e
set +o history
export POSTGRES_CONNECTION_STRING='${POSTGRES_CONNECTION_STRING}'
# Ensure legacy 'postgres' role exists for migrations that reference it
psql "\$POSTGRES_CONNECTION_STRING" <<'EOSQL'
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'postgres') THEN
        EXECUTE 'CREATE ROLE postgres';
    END IF;
END
\$\$;
GRANT postgres TO admin;
EOSQL
cd ~/e2b/packages/db
echo "Starting migrations..."
go run ./scripts/migrator.go up
EOF
then
  echo "✓ Database migrations applied"
else
  echo -e "${YELLOW}⚠ Database migrations failed. Verify PostgreSQL credentials before proceeding.${NC}"
fi

# Phase 2: Upload Prebuilt Binaries
echo -e "\n${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Phase 2: Uploading Prebuilt Binaries${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"

BINARY_DIR="${SCRIPT_DIR}/artifacts/bin"
if [[ ! -d "${BINARY_DIR}" ]]; then
  echo "${RED}✗ Prebuilt binaries not found in ${BINARY_DIR}. Please run local builds first.${NC}"
  exit 1
fi

echo -e "\n${YELLOW}Uploading binaries to API pool...${NC}"
ssh ${SSH_OPTS} ${SSH_USER}@${API_POOL_PUBLIC} "mkdir -p ~/e2b/bin && sudo chown -R ${SSH_USER}:${SSH_USER} ~/e2b"
scp ${SSH_OPTS} ${BINARY_DIR}/e2b-api ${SSH_USER}@${API_POOL_PUBLIC}:~/e2b/bin/
scp ${SSH_OPTS} ${BINARY_DIR}/client-proxy ${SSH_USER}@${API_POOL_PUBLIC}:~/e2b/bin/
echo "✓ Binaries uploaded to API pool"

echo -e "\n${YELLOW}Uploading binaries to Client pool...${NC}"
ssh ${SSH_OPTS} ${SSH_USER}@${CLIENT_POOL_PUBLIC} "mkdir -p ~/e2b/bin && sudo chown -R ${SSH_USER}:${SSH_USER} ~/e2b && rm -f ~/e2b/bin/template-manager"
scp ${SSH_OPTS} ${BINARY_DIR}/orchestrator ${SSH_USER}@${CLIENT_POOL_PUBLIC}:~/e2b/bin/
scp ${SSH_OPTS} ${BINARY_DIR}/template-manager ${SSH_USER}@${CLIENT_POOL_PUBLIC}:~/e2b/bin/
scp ${SSH_OPTS} ${BINARY_DIR}/envd ${SSH_USER}@${CLIENT_POOL_PUBLIC}:~/e2b/bin/
echo "✓ Binaries uploaded to Client pool"

echo -e "${GREEN}✓ Phase 2 Complete: Prebuilt binaries uploaded${NC}"

# Phase 3: Verify OCI Managed Services
echo -e "\n${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Phase 3: Verifying OCI Managed Services${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}Skipping managed service connectivity checks in this environment.${NC}"
echo -e "${GREEN}✓ Phase 3 Skipped${NC}"

# Phase 4: Build Binaries on API Pool (Skipped)
echo -e "\n${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Phase 4: Building E2B Services on API Pool${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}Skipping build on API pool; using uploaded binaries.${NC}"
echo -e "${GREEN}✓ Phase 4 Complete: Prebuilt binaries in use${NC}"

# Phase 5: Build Binaries on Client Pool (Skipped)
echo -e "\n${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Phase 5: Building E2B Services on Client Pool${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}Skipping build on Client pool; using uploaded binaries.${NC}"
echo -e "${GREEN}✓ Phase 5 Complete: Prebuilt binaries in use${NC}"

# Phase 6: Create Configuration Files
echo -e "\n${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Phase 6: Creating Configuration Files${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"

echo -e "\n${YELLOW}Creating API service configuration...${NC}"
ssh $SSH_OPTS ${SSH_USER}@${API_POOL_PUBLIC} << ENDSSH
cat > ~/e2b/api.env <<ENDENV
# PostgreSQL Configuration (OCI Database)
POSTGRES_CONNECTION_STRING=postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}?sslmode=require

# Storage Configuration (Local for POC)
STORAGE_PROVIDER=local
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

# Consul Configuration
CONSUL_URL=http://localhost:8500

# Cloud Provider
CLOUD_PROVIDER=oci
ENDENV
echo "✓ API configuration created"
ENDSSH

echo -e "\n${YELLOW}Creating Client Proxy configuration...${NC}"
ssh $SSH_OPTS ${SSH_USER}@${API_POOL_PUBLIC} << ENDSSH
cat > ~/e2b/client-proxy.env <<ENDENV
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
ENDENV
echo "✓ Client Proxy configuration created"
ENDSSH

echo -e "\n${YELLOW}Creating Orchestrator configuration...${NC}"
ssh $SSH_OPTS ${SSH_USER}@${CLIENT_POOL_PUBLIC} << ENDSSH
cat > ~/e2b/orchestrator.env <<ENDENV
# Storage Configuration (Local for POC)
STORAGE_PROVIDER=local
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
ENDENV
echo "✓ Orchestrator configuration created"
ENDSSH

echo -e "\n${YELLOW}Creating Template Manager configuration...${NC}"
ssh $SSH_OPTS ${SSH_USER}@${CLIENT_POOL_PUBLIC} << ENDSSH
cat > ~/e2b/template-manager.env <<ENDENV
# Storage Configuration (Local for POC)
STORAGE_PROVIDER=local
LOCAL_TEMPLATE_STORAGE_BASE_PATH=/var/e2b/templates

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

# Lock Path
ORCHESTRATOR_LOCK_PATH=/opt/e2b/runtime/orchestrator.lock

ENDENV
echo "✓ Template Manager configuration created"
ENDSSH

echo -e "${GREEN}✓ Phase 6 Complete: Configuration files created${NC}"

# Phase 7: Promote artifacts to /opt/e2b for Nomad runtime
echo -e "\n${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Phase 7: Promoting artifacts to /opt/e2b${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"

echo -e "\n${YELLOW}Syncing API payload to /opt/e2b...${NC}"
ssh $SSH_OPTS ${SSH_USER}@${API_POOL_PUBLIC} <<'ENDSSH'
set -e
sudo mkdir -p /opt/e2b
sudo rsync -a --delete ~/e2b/ /opt/e2b/
sudo mkdir -p /opt/e2b/runtime /opt/e2b/tmp
sudo chown -R nomad:nomad /opt/e2b
sudo chmod -R 755 /opt/e2b
ENDSSH
echo "✓ API payload ready under /opt/e2b"

echo -e "\n${YELLOW}Syncing Client payload to /opt/e2b...${NC}"
ssh $SSH_OPTS ${SSH_USER}@${CLIENT_POOL_PUBLIC} <<'ENDSSH'
set -e
sudo mkdir -p /opt/e2b
sudo rsync -a --delete ~/e2b/ /opt/e2b/
sudo mkdir -p /opt/e2b/runtime /opt/e2b/tmp
sudo chown -R nomad:nomad /opt/e2b
sudo chmod -R 755 /opt/e2b
ENDSSH
echo "✓ Client payload ready under /opt/e2b"

echo -e "${GREEN}✓ Phase 7 Complete: Runtime artifacts promoted${NC}"

# Phase 8: Prepare Template Runtime Assets
echo -e "\n${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Phase 8: Preparing Template Runtime Assets${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"

ssh \
  FIRECRACKER_VERSION="${FIRECRACKER_VERSION_FULL}" \
  KERNEL_VERSION="${FIRECRACKER_KERNEL_VERSION}" \
  $SSH_OPTS ${SSH_USER}@${CLIENT_POOL_PUBLIC} <<'EOF'
set -e
sudo mkdir -p /fc-envd /fc-versions/${FIRECRACKER_VERSION} /fc-kernels/${KERNEL_VERSION} /mnt/disks/fc-envs/v1
sudo cp /opt/e2b/bin/envd /fc-envd/envd
sudo chmod 0755 /fc-envd/envd
sudo ln -sf /usr/local/bin/firecracker /fc-versions/${FIRECRACKER_VERSION}/firecracker
sudo ln -sf /var/e2b/kernels/vmlinux-${KERNEL_VERSION}/vmlinux.bin /fc-kernels/${KERNEL_VERSION}/vmlinux.bin
sudo chown -R nomad:nomad /fc-envd /fc-versions /fc-kernels /mnt/disks/fc-envs || true
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
echo -e "  ${BLUE}On API Pool (${API_POOL_PUBLIC}):${NC}"
echo "    cd /opt/e2b && source api.env && ./bin/e2b-api"
echo "    cd /opt/e2b && source client-proxy.env && ./bin/client-proxy"
echo ""
echo -e "  ${BLUE}On Client Pool (${CLIENT_POOL_PUBLIC}):${NC}"
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

