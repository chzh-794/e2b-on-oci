-- +goose Up
ALTER TABLE tiers
    ADD COLUMN "max_vcpu" bigint NOT NULL default '8'::bigint,
    ADD COLUMN "max_ram_mb" bigint NOT NULL DEFAULT '8096'::bigint;
-- +goose Down
ALTER TABLE tiers
    DROP COLUMN IF EXISTS "max_vcpu",
    DROP COLUMN IF EXISTS "max_ram_mb";
