-- Cluster Configuration Verification SQL
-- Run this on the database to check cluster endpoint and token

\echo '════════════════════════════════════════════════════════════════'
\echo '  CLUSTER CONFIGURATION VERIFICATION'
\echo '════════════════════════════════════════════════════════════════'
\echo ''

\echo 'Expected Configuration:'
\echo '  Endpoint: 10.0.2.251:3001'
\echo '  Token: E2bEdgeSecret2025!'
\echo '  Endpoint TLS: false'
\echo ''

\echo 'Database (clusters table):'
SELECT 
    id::text as cluster_id,
    endpoint,
    endpoint_tls,
    CASE 
        WHEN endpoint = '10.0.2.251:3001' THEN '✓ MATCH'
        ELSE '✗ MISMATCH (expected: 10.0.2.251:3001, got: ' || endpoint || ')'
    END as endpoint_status,
    CASE 
        WHEN token = 'E2bEdgeSecret2025!' THEN '✓ MATCH'
        ELSE '✗ MISMATCH (got: ' || LEFT(token, 20) || '...)'
    END as token_status,
    LEFT(token, 20) || '...' as token_preview
FROM clusters;

\echo ''
\echo 'Team-Cluster Association:'
SELECT 
    t.id::text as team_id,
    t.name as team_name,
    t.cluster_id::text,
    c.endpoint as cluster_endpoint,
    CASE 
        WHEN c.endpoint = '10.0.2.251:3001' THEN '✓'
        ELSE '✗'
    END as endpoint_ok
FROM teams t
LEFT JOIN clusters c ON t.cluster_id = c.id;

\echo ''
\echo '════════════════════════════════════════════════════════════════'

