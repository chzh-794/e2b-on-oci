-- +goose Up
-- +goose StatementBegin
-- Modify RLS policy on access_tokens to allow admin user (API service) to query tokens
-- The API service connects as 'admin' user and needs to validate access tokens,
-- but the original policy only allowed authenticated users with auth.uid() = user_id
-- This policy allows:
--   - admin user to query any token (required for API token validation)
--   - authenticated users to query only their own tokens (security preserved)
-- RLS remains enabled - we modify the policy, not disable RLS
DROP POLICY IF EXISTS "Enable select for users based on user_id" ON "public"."access_tokens";
CREATE POLICY "Allow admin or authenticated users" ON "public"."access_tokens"
  FOR SELECT
  TO authenticated, admin
  USING (
    current_user = 'admin' OR 
    auth.uid() = user_id
  );
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DROP POLICY IF EXISTS "Allow admin or authenticated users" ON "public"."access_tokens";
CREATE POLICY "Enable select for users based on user_id" ON "public"."access_tokens"
  FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);
-- +goose StatementEnd

