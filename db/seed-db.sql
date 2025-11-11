-- seed-db.sql

BEGIN;
-- 临时禁用触发器以避免自动生成
SET session_replication_role = 'replica';
-- crate temp table
CREATE TEMP TABLE temp_new_user (id uuid);
-- insert data to auth.users and save ID to temp table
WITH new_user AS (INSERT INTO auth.users (id, email) VALUES (gen_random_uuid(), :'email') RETURNING id)
INSERT INTO temp_new_user SELECT id FROM new_user;
-- insert team
INSERT INTO teams (id, name, email, tier, created_at, slug) VALUES (:'teamID'::uuid, 'E2B', :'email', 'base_v1', CURRENT_TIMESTAMP,LOWER(REGEXP_REPLACE(SPLIT_PART(:'email', '@', 1), '[^a-zA-Z0-9]', '-', 'g')));
-- insert user team
INSERT INTO users_teams (id, is_default, user_id, team_id) SELECT nextval('users_teams_id_seq'), true, id, :'teamID'::uuid FROM temp_new_user;
-- insert e2b access_token
INSERT INTO access_tokens (access_token, user_id, created_at) SELECT :'accessToken', id, CURRENT_TIMESTAMP FROM temp_new_user;
-- insert team_api
INSERT INTO team_api_keys (id, api_key, team_id, name, created_at) VALUES (gen_random_uuid(), :'teamAPIKey', :'teamID'::uuid, 'Default API Key', CURRENT_TIMESTAMP);
-- insert envs
INSERT INTO envs (id, team_id, public, created_at, updated_at, build_count, spawn_count) VALUES ('rki5dems9wqfm4r03t7g', :'teamID'::uuid, true, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, 1, 0);
-- drop temp table
DROP TABLE temp_new_user;
COMMIT;

\echo '数据库已成功初始化'
