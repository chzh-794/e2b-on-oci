\set ON_ERROR_STOP on

BEGIN;

-- Insert or fetch user (Supabase auth.users lacks unique(email) in OCI)
WITH existing_user AS (
    SELECT id FROM auth.users WHERE email = :'email' LIMIT 1
), inserted_user AS (
    INSERT INTO auth.users (id, email)
    SELECT gen_random_uuid(), :'email'
    WHERE NOT EXISTS (SELECT 1 FROM existing_user)
    RETURNING id
), chosen_user AS (
    SELECT id FROM inserted_user
    UNION ALL
    SELECT id FROM existing_user
    LIMIT 1
)
SELECT id INTO TEMP TABLE temp_new_user FROM chosen_user;

-- Insert or update team
INSERT INTO teams (id, name, email, tier)
VALUES (
    :'teamID'::uuid,
    'E2B OCI POC',
    :'email',
    'base_v1'
)
ON CONFLICT (id) DO UPDATE
SET name = EXCLUDED.name,
    email = EXCLUDED.email,
    tier = EXCLUDED.tier;

-- Insert user-team relationship
INSERT INTO users_teams (id, is_default, user_id, team_id)
SELECT nextval('users_teams_id_seq'), true, id, :'teamID'::uuid
FROM temp_new_user
ON CONFLICT (user_id, team_id) DO UPDATE
SET is_default = true;

-- Ensure no other teams remain default for this user (handles prior seeds)
UPDATE users_teams
SET is_default = false
WHERE user_id IN (SELECT id FROM temp_new_user)
  AND team_id <> :'teamID'::uuid;

UPDATE users_teams
SET is_default = true
WHERE user_id IN (SELECT id FROM temp_new_user)
  AND team_id = :'teamID'::uuid;

-- Replace access token for user
DELETE FROM access_tokens WHERE user_id IN (SELECT id FROM temp_new_user);
INSERT INTO access_tokens (access_token, user_id, created_at)
SELECT :'accessToken', id, CURRENT_TIMESTAMP
FROM temp_new_user;

-- Replace team API key
DELETE FROM team_api_keys WHERE team_id = :'teamID'::uuid;
INSERT INTO team_api_keys (id, api_key, team_id, name, created_at)
VALUES (
    gen_random_uuid(),
    :'teamAPIKey',
    :'teamID'::uuid,
    'Default API Key',
    CURRENT_TIMESTAMP
);

-- Clean up
DROP TABLE IF EXISTS temp_new_user;

COMMIT;

\echo 'Database seeded successfully!'