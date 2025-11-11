-- Simple seed for E2B POC
-- Creates minimal user, team, and API key

BEGIN;

-- Disable triggers
SET session_replication_role = 'replica';

-- Create temp table for user ID
CREATE TEMP TABLE temp_new_user (id uuid);

-- Insert user and save ID
WITH new_user AS (
    INSERT INTO auth.users (id, email) 
    VALUES (gen_random_uuid(), :'email') 
    RETURNING id
)
INSERT INTO temp_new_user SELECT id FROM new_user;

-- Insert team
INSERT INTO teams (id, name, email, tier, created_at, slug) 
VALUES (
    :'teamID'::uuid, 
    'E2B OCI POC', 
    :'email', 
    'base_v1', 
    CURRENT_TIMESTAMP,
    LOWER(REGEXP_REPLACE(SPLIT_PART(:'email', '@', 1), '[^a-zA-Z0-9]', '-', 'g'))
);

-- Insert user-team relationship
INSERT INTO users_teams (id, is_default, user_id, team_id) 
SELECT nextval('users_teams_id_seq'), true, id, :'teamID'::uuid 
FROM temp_new_user;

-- Insert access token
INSERT INTO access_tokens (access_token, user_id, created_at) 
SELECT :'accessToken', id, CURRENT_TIMESTAMP 
FROM temp_new_user;

-- Insert team API key
INSERT INTO team_api_keys (id, api_key, team_id, name, created_at) 
VALUES (
    gen_random_uuid(), 
    :'teamAPIKey', 
    :'teamID'::uuid, 
    'Default API Key', 
    CURRENT_TIMESTAMP
);

-- Clean up
DROP TABLE temp_new_user;

COMMIT;

\echo 'Database seeded successfully!'

