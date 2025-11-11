-- +goose Up
ALTER TABLE snapshots
ADD COLUMN env_secure boolean NOT NULL DEFAULT false;

-- +goose Down
ALTER TABLE snapshots
DROP COLUMN IF EXISTS env_secure;
