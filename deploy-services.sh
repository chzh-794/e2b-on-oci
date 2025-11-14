#!/bin/bash
# Deploy E2B services via Nomad

set -e

SERVER_POOL_PUBLIC="10.0.2.231"

SSH_USER="ubuntu"
SSH_KEY="$HOME/.ssh/id_rsa"
BASTION_HOST="192.29.245.106"
SSH_OPTS="-i ${SSH_KEY} -o StrictHostKeyChecking=no -o ProxyJump=${SSH_USER}@${BASTION_HOST}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOMAD_DIR="${SCRIPT_DIR}/nomad"

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║       Deploying E2B Services via Nomad                    ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Copy Nomad job files to server
echo -e "${YELLOW}Copying Nomad job definitions to Server Pool...${NC}"
ssh $SSH_OPTS ${SSH_USER}@${SERVER_POOL_PUBLIC} "mkdir -p ~/nomad"
scp $SSH_OPTS ${NOMAD_DIR}/*.hcl ${SSH_USER}@${SERVER_POOL_PUBLIC}:~/nomad/
echo -e "${GREEN}✓ Job definitions copied${NC}"
echo ""

# Deploy Orchestrator (system job - runs on all client nodes)
echo -e "${GREEN}Step 1: Deploying Orchestrator${NC}"
ssh $SSH_OPTS ${SSH_USER}@${SERVER_POOL_PUBLIC} << 'ENDSSH'
cd ~/nomad
/usr/local/bin/nomad job run orchestrator.hcl
sleep 3
echo ""
echo "Orchestrator deployment status:"
/usr/local/bin/nomad job status orchestrator
ENDSSH
echo -e "${GREEN}✓ Orchestrator deployed${NC}"
echo ""

# Deploy API
echo -e "${GREEN}Step 2: Deploying E2B API${NC}"
ssh $SSH_OPTS ${SSH_USER}@${SERVER_POOL_PUBLIC} << 'ENDSSH'
cd ~/nomad
/usr/local/bin/nomad job run api.hcl
sleep 3
echo ""
echo "API deployment status:"
/usr/local/bin/nomad job status api
ENDSSH
echo -e "${GREEN}✓ E2B API deployed${NC}"
echo ""

# Deploy Client Proxy
echo -e "${GREEN}Step 3: Deploying Client Proxy${NC}"
ssh $SSH_OPTS ${SSH_USER}@${SERVER_POOL_PUBLIC} << 'ENDSSH'
cd ~/nomad
/usr/local/bin/nomad job run client-proxy.hcl
sleep 3
echo ""
echo "Client Proxy deployment status:"
/usr/local/bin/nomad job status client-proxy
ENDSSH
echo -e "${GREEN}✓ Client Proxy deployed${NC}"
echo ""

# Deploy Template Manager
echo -e "${GREEN}Step 4: Deploying Template Manager${NC}"
ssh $SSH_OPTS ${SSH_USER}@${SERVER_POOL_PUBLIC} << 'ENDSSH'
cd ~/nomad
/usr/local/bin/nomad job run template-manager.hcl
sleep 3
echo ""
echo "Template Manager deployment status:"
/usr/local/bin/nomad job status template-manager
ENDSSH
echo -e "${GREEN}✓ Template Manager deployed${NC}"
echo ""

# Verify all services
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Verifying All Services${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo ""

ssh $SSH_OPTS ${SSH_USER}@${SERVER_POOL_PUBLIC} << 'ENDSSH'
echo "=== All Nomad Jobs ==="
/usr/local/bin/nomad job status

echo ""
echo "=== Consul Services ==="
/usr/local/bin/consul catalog services
ENDSSH

# Summary
echo ""
echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║       All Services Deployed!                               ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}✓ Orchestrator running on Client Pool${NC}"
echo -e "${GREEN}✓ E2B API running on API Pool${NC}"
echo -e "${GREEN}✓ Client Proxy running on API Pool${NC}"
echo ""
echo -e "${YELLOW}Access Points:${NC}"
echo "  Nomad UI:  http://${SERVER_POOL_PUBLIC}:4646"
echo "  Consul UI: http://${SERVER_POOL_PUBLIC}:8500"
echo "  E2B API:   http://${API_POOL_PUBLIC}:8080"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo "1. Test API endpoint: curl http://${API_POOL_PUBLIC}:8080/health"
echo "2. Create a test template"
echo "3. Test sandbox lifecycle"
echo ""

