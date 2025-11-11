#!/bin/bash
# Initialize E2B Database on OCI PostgreSQL

set -e

# Database configuration
POSTGRES_HOST="10.1.2.168"
POSTGRES_PORT="5432"
POSTGRES_USER="postgres"
POSTGRES_PASSWORD="E2bPostgres123!"
POSTGRES_DB="postgres"

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
psql -h ${POSTGRES_HOST} -p ${POSTGRES_PORT} -U ${POSTGRES_USER} -d ${POSTGRES_DB} -f ${SCRIPT_DIR}/migration.sql

if [ $? -eq 0 ]; then
    echo "✓ Database schema created"
else
    echo "✗ Migration failed"
    exit 1
fi

echo ""

# Step 2: Seed database with test user/team
echo "Step 2: Seeding database with test user and team..."
echo "  Email: ${EMAIL}"
echo "  Team ID: ${TEAM_ID}"
echo ""

psql -h ${POSTGRES_HOST} -p ${POSTGRES_PORT} -U ${POSTGRES_USER} -d ${POSTGRES_DB} \
    -v email="${EMAIL}" \
    -v teamID="${TEAM_ID}" \
    -v accessToken="${ACCESS_TOKEN}" \
    -v teamAPIKey="${TEAM_API_KEY}" \
    -f ${SCRIPT_DIR}/simple-seed.sql

if [ $? -eq 0 ]; then
    echo "✓ Database seeded"
else
    echo "✗ Seeding failed"
    exit 1
fi

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║       Database Initialization Complete!                    ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "✓ Database schema created"
echo "✓ Test user and team created"
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

