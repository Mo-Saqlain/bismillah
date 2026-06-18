-- Bismillah Constructions ERP — Supabase schema.
--
-- This file mirrors the local SQLite schema (lib/data/db/local_db.dart) so
-- the Flutter app can push every domain row to Postgres for cloud backup
-- and multi-device sync.
--
-- Conventions:
--   * Every table has a `tenant_id uuid` column. The Flutter app
--     generates one tenant_id per operator on first sync and copies it
--     to any second device. Every query is filtered by tenant_id so two
--     unrelated installs never see each other's data.
--   * Every table has `updated_at timestamptz NOT NULL DEFAULT now()`
--     and an ON UPDATE trigger so the sync cursor (`updated_at > X`)
--     works without per-write hooks.
--   * Open RLS within the project — single-operator app, no auth. The
--     anon (publishable) key is the only credential. Anyone with the
--     APK or the anon key can read everything in this project, which is
--     the chosen security model (matches the "no authentication"
--     product constraint).
--   * INSERT-only conflict resolution on the client: pulled rows that
--     already exist locally are skipped, so local writes are never
--     overwritten. The server is effectively a mirror of every device's
--     writes plus rows that arrived from other devices.
--
-- Apply this once via Supabase Dashboard → SQL Editor → New Query, or
-- via `supabase db push` if you've initialised the CLI.

-- ───────────────────────────────────────────────────────────────────────
--  Helpers
-- ───────────────────────────────────────────────────────────────────────

-- Generic AFTER UPDATE trigger that bumps `updated_at`. Attached to
-- every sync table below.
CREATE OR REPLACE FUNCTION bump_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

-- ───────────────────────────────────────────────────────────────────────
--  Tables (mirrors of local SQLite)
-- ───────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS projects (
  id                  text PRIMARY KEY,
  tenant_id           uuid NOT NULL,
  name                text NOT NULL,
  model               text NOT NULL,
  status              text NOT NULL,
  client_name         text,
  site_address        text,
  budget              numeric,
  project_manager     text,
  service_fee_percent numeric,
  completion_percent  integer NOT NULL DEFAULT 0,
  is_archived         integer NOT NULL DEFAULT 0,
  archived_at         timestamptz,
  created_at          timestamptz NOT NULL,
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_projects_tenant_updated
  ON projects (tenant_id, updated_at);

CREATE TABLE IF NOT EXISTS suppliers (
  id            text PRIMARY KEY,
  tenant_id     uuid NOT NULL,
  name          text NOT NULL,
  phone         text,
  category      text,
  tax_status    text,
  bank_details  text,
  is_archived   integer NOT NULL DEFAULT 0,
  archived_at   timestamptz,
  created_at    timestamptz NOT NULL,
  updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_suppliers_tenant_updated
  ON suppliers (tenant_id, updated_at);

CREATE TABLE IF NOT EXISTS banks (
  id            text PRIMARY KEY,
  tenant_id     uuid NOT NULL,
  name          text NOT NULL,
  account_no    text,
  is_archived   integer NOT NULL DEFAULT 0,
  archived_at   timestamptz,
  created_at    timestamptz NOT NULL,
  updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_banks_tenant_updated
  ON banks (tenant_id, updated_at);

CREATE TABLE IF NOT EXISTS counter_entities (
  id          text PRIMARY KEY,
  tenant_id   uuid NOT NULL,
  name        text NOT NULL,
  type        text NOT NULL,
  amount      numeric NOT NULL DEFAULT 0,
  created_at  timestamptz NOT NULL,
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_counter_entities_tenant_updated
  ON counter_entities (tenant_id, updated_at);

CREATE TABLE IF NOT EXISTS journal_entries (
  id              text PRIMARY KEY,
  tenant_id       uuid NOT NULL,
  transaction_id  text NOT NULL,
  account_id      text NOT NULL,
  project_id      text,
  supplier_id     text,
  debit           numeric NOT NULL DEFAULT 0,
  credit          numeric NOT NULL DEFAULT 0,
  description     text,
  is_deleted      integer NOT NULL DEFAULT 0,
  deleted_at      timestamptz,
  created_at      timestamptz NOT NULL,
  updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_journal_entries_tenant_updated
  ON journal_entries (tenant_id, updated_at);
CREATE INDEX IF NOT EXISTS idx_journal_entries_tenant_txn
  ON journal_entries (tenant_id, transaction_id);

CREATE TABLE IF NOT EXISTS material_inventory (
  id              text PRIMARY KEY,
  tenant_id       uuid NOT NULL,
  project_id      text NOT NULL,
  supplier_id     text,
  transaction_id  text,
  material_type   text NOT NULL,
  unit            text NOT NULL,
  -- nullable (local schema v17): a material buy may be logged without a
  -- quantity; such rows carry a null rate and are skipped by the price trend.
  quantity        numeric,
  rate            numeric,
  total_cost      numeric NOT NULL,
  txn_type        text NOT NULL,
  is_deleted      integer NOT NULL DEFAULT 0,
  deleted_at      timestamptz,
  created_at      timestamptz NOT NULL,
  updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_material_inventory_tenant_updated
  ON material_inventory (tenant_id, updated_at);

CREATE TABLE IF NOT EXISTS material_types (
  id           text PRIMARY KEY,
  tenant_id    uuid NOT NULL,
  name         text NOT NULL,
  is_builtin   integer NOT NULL DEFAULT 0,
  sort_order   integer NOT NULL DEFAULT 0,
  uom_typ      text,
  uom          text,
  cov_rate     numeric,
  waste_f      numeric,
  lead_d       integer,
  dims         text,
  created_at   timestamptz NOT NULL,
  updated_at   timestamptz NOT NULL DEFAULT now(),
  -- Name is unique within a tenant, not globally (two operators could
  -- both have a "Cement" row).
  UNIQUE (tenant_id, name)
);
CREATE INDEX IF NOT EXISTS idx_material_types_tenant_updated
  ON material_types (tenant_id, updated_at);

CREATE TABLE IF NOT EXISTS labour_types (
  id                  text PRIMARY KEY,
  tenant_id           uuid NOT NULL,
  name                text NOT NULL,
  description         text,
  default_daily_rate  numeric,
  created_at          timestamptz NOT NULL,
  updated_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, name)
);
CREATE INDEX IF NOT EXISTS idx_labour_types_tenant_updated
  ON labour_types (tenant_id, updated_at);

CREATE TABLE IF NOT EXISTS notes (
  id           text PRIMARY KEY,
  tenant_id    uuid NOT NULL,
  entity_type  text NOT NULL,
  entity_id    text NOT NULL,
  body         text NOT NULL,
  is_pinned    integer NOT NULL DEFAULT 0,
  is_deleted   integer NOT NULL DEFAULT 0,
  deleted_at   timestamptz,
  created_at   timestamptz NOT NULL,
  updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_notes_tenant_updated
  ON notes (tenant_id, updated_at);

CREATE TABLE IF NOT EXISTS follow_ups (
  id               text PRIMARY KEY,
  tenant_id        uuid NOT NULL,
  project_id       text,
  supplier_id      text,
  title            text NOT NULL,
  note             text,
  expected_date    timestamptz,
  priority         text NOT NULL DEFAULT 'medium',
  status           text NOT NULL DEFAULT 'pending',
  amount_estimate  numeric,
  is_deleted       integer NOT NULL DEFAULT 0,
  deleted_at       timestamptz,
  created_at       timestamptz NOT NULL,
  resolved_at      timestamptz,
  updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_followups_tenant_updated
  ON follow_ups (tenant_id, updated_at);

-- ───────────────────────────────────────────────────────────────────────
--  Bump-on-update triggers
-- ───────────────────────────────────────────────────────────────────────

DO $$
DECLARE
  t text;
  tables text[] := ARRAY[
    'projects','suppliers','banks','counter_entities','journal_entries',
    'material_inventory','material_types','labour_types','notes','follow_ups'
  ];
BEGIN
  FOREACH t IN ARRAY tables LOOP
    EXECUTE format(
      'DROP TRIGGER IF EXISTS trg_bump_updated ON %I', t);
    EXECUTE format(
      'CREATE TRIGGER trg_bump_updated BEFORE UPDATE ON %I
       FOR EACH ROW EXECUTE FUNCTION bump_updated_at()', t);
  END LOOP;
END$$;

-- ───────────────────────────────────────────────────────────────────────
--  Row-Level Security
-- ───────────────────────────────────────────────────────────────────────
--
-- Open RLS within this project — every client uses the anon key and
-- filters its own queries by `tenant_id`. This matches the
-- single-operator design (no Supabase Auth, no per-user JWT). Anyone
-- with the project's anon key can read everything; restrict access to
-- the project itself by keeping the anon key out of public source.
-- If you ever want multi-tenant isolation, replace these policies with
-- `using (tenant_id = (auth.jwt()->>'tenant_id')::uuid)` and stamp the
-- tenant id into a custom claim.

DO $$
DECLARE
  t text;
  tables text[] := ARRAY[
    'projects','suppliers','banks','counter_entities','journal_entries',
    'material_inventory','material_types','labour_types','notes','follow_ups'
  ];
BEGIN
  FOREACH t IN ARRAY tables LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS open_all ON %I', t);
    EXECUTE format(
      'CREATE POLICY open_all ON %I FOR ALL TO anon, authenticated
       USING (true) WITH CHECK (true)', t);
  END LOOP;
END$$;
