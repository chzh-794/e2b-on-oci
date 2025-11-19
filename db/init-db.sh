#!/bin/bash
# Initialize E2B Database on OCI PostgreSQL

set -e

# Load deploy.env if available (only exists on the workstation)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${REPO_ROOT}/deploy.env"
if [[ -f "${CONFIG_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
  set +a
fi

# Database configuration (can be overridden via env vars or deploy.env)
POSTGRES_HOST=${POSTGRES_HOST:-"10.1.2.168"}
POSTGRES_PORT=${POSTGRES_PORT:-"5432"}
POSTGRES_USER=${POSTGRES_USER:-"postgres"}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-"E2bPostgres123!"}
POSTGRES_DB=${POSTGRES_DB:-"postgres"}

# E2B user configuration
EMAIL="admin@e2b-oci-poc.local"
TEAM_ID=$(uuidgen)
# Generate tokens with required prefixes
ACCESS_TOKEN="sk_e2b_$(openssl rand -hex 15)"  # sk_e2b_ + 30 chars = 37 chars total
TEAM_API_KEY="e2b_$(openssl rand -hex 18)"     # e2b_ + 36 chars = 40 chars total

export PGPASSWORD="${POSTGRES_PASSWORD}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "╔════════════════════════════════════════════════════════════╗"
echo "║       E2B Database Initialization                          ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "Database: ${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}"
echo "User: ${POSTGRES_USER}"
echo ""

# Step 1: Run migrations (create schema)
echo "Step 1: Running migrations (creating database schema)..."
psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -f "${SCRIPT_DIR}/migration.sql"

if [ $? -eq 0 ]; then
    echo "✓ Database schema created"
else
    echo "✗ Migration failed"
    exit 1
fi

echo ""

# Note: Legacy columns (dockerfile, build_id, vcpu, ram_mb, etc.) were moved to env_builds table
# by migration 20240315165236_create_env_builds.sql, so they no longer exist in envs table.
# This is expected and correct.

# Step 2: Seed database with test user/team
echo "Step 2: Seeding database with test user and team..."
echo "  Email: ${EMAIL}"
echo "  Team ID: ${TEAM_ID}"
echo ""

psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
    -v email="${EMAIL}" \
    -v teamID="${TEAM_ID}" \
    -v accessToken="${ACCESS_TOKEN}" \
    -v teamAPIKey="${TEAM_API_KEY}" \
    -f "${SCRIPT_DIR}/simple-seed.sql"

if [ $? -eq 0 ]; then
    echo "✓ Database seeded"
else
    echo "✗ Seeding failed"
    exit 1
fi

echo ""

# Step 3: Create cluster entry and associate team (required for sandbox exec)
echo "Step 3: Setting up compute cluster for sandbox exec..."
# Get API pool IP from deploy.env or use default
API_POOL_IP=${API_POOL_PRIVATE:-${API_POOL_PUBLIC:-"127.0.0.1"}}
# Use the same EDGE_SECRET that client-proxy uses (must match deploy-poc.sh EDGE_SERVICE_SECRET)
# This is the token the API uses to authenticate with the edge API (client-proxy)
EDGE_SECRET=${EDGE_SERVICE_SECRET:-"E2bEdgeSecret2025!"}
CLUSTER_ID=$(uuidgen)

psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
    -v teamID="'${TEAM_ID}'" \
    -v clusterID="'${CLUSTER_ID}'" \
    -v endpoint="'${API_POOL_IP}:3001'" \
    -v edgeSecret="'${EDGE_SECRET}'" <<'SQL'
-- Create cluster entry pointing to client-proxy (edge API)
INSERT INTO clusters (id, endpoint, endpoint_tls, token)
VALUES (:clusterID::uuid, :endpoint, false, :edgeSecret)
ON CONFLICT (id) DO UPDATE SET endpoint = EXCLUDED.endpoint, token = EXCLUDED.token;

-- Associate team with cluster (required for sandbox exec endpoint)
UPDATE teams SET cluster_id = :clusterID::uuid WHERE id = :teamID::uuid;

-- Verify cluster setup
SELECT 
    t.id as team_id, 
    t.name as team_name, 
    t.cluster_id, 
    c.endpoint, 
    c.endpoint_tls 
FROM teams t 
LEFT JOIN clusters c ON t.cluster_id = c.id 
WHERE t.id = :teamID::uuid;
SQL

if [ $? -eq 0 ]; then
    echo "✓ Cluster configured and team associated"
else
    echo "✗ Cluster setup failed"
    exit 1
fi

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║       Database Initialization Complete!                    ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "✓ Database schema created"
echo "✓ Test user and team created"
echo "✓ Compute cluster configured"
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "Your E2B API Credentials:"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "  Email:        ${EMAIL}"
echo "  Team ID:      ${TEAM_ID}"
echo "  API Key:      ${TEAM_API_KEY}"
echo "  Access Token: ${ACCESS_TOKEN}"
echo ""
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "To test the API:"
echo "  export E2B_API_KEY='${TEAM_API_KEY}'"
echo "  curl -H 'X-API-Key: \${E2B_API_KEY}' http://129.149.60.176/health"
echo ""
echo "Save these credentials!"
echo ""

