-- Bismillah Constructions — schema migration 0008.
--
-- Create `app_users` and `access_requests` tables for user authentication,
-- superuser role management, and access requesting workflow.
--
-- Apply once via Supabase Dashboard -> SQL Editor. Idempotent.

CREATE TABLE IF NOT EXISTS app_users (
  id            text PRIMARY KEY,
  tenant_id     uuid NOT NULL,
  username      text NOT NULL,
  password_hash text NOT NULL,
  role          text NOT NULL DEFAULT 'user',
  status        text NOT NULL DEFAULT 'active',
  is_deleted    integer NOT NULL DEFAULT 0,
  created_at    timestamptz NOT NULL,
  updated_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, username)
);
CREATE INDEX IF NOT EXISTS idx_app_users_tenant_updated
  ON app_users (tenant_id, updated_at);

CREATE TABLE IF NOT EXISTS access_requests (
  id             text PRIMARY KEY,
  tenant_id      uuid NOT NULL,
  username       text NOT NULL,
  full_name      text,
  phone_or_email text,
  status         text NOT NULL DEFAULT 'pending',
  is_deleted     integer NOT NULL DEFAULT 0,
  created_at     timestamptz NOT NULL,
  updated_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_access_requests_tenant_updated
  ON access_requests (tenant_id, updated_at);

-- Helper: Generic AFTER UPDATE trigger that bumps updated_at
CREATE OR REPLACE FUNCTION bump_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

-- Attach bump-on-update triggers
DO $$
DECLARE
  t text;
  tables text[] := ARRAY['app_users', 'access_requests'];
BEGIN
  FOREACH t IN ARRAY tables LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_bump_updated ON %I', t);
    EXECUTE format(
      'CREATE TRIGGER trg_bump_updated BEFORE UPDATE ON %I
       FOR EACH ROW EXECUTE FUNCTION bump_updated_at()', t);
  END LOOP;
END$$;

-- Enable Row-Level Security
DO $$
DECLARE
  t text;
  tables text[] := ARRAY['app_users', 'access_requests'];
BEGIN
  FOREACH t IN ARRAY tables LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS open_all ON %I', t);
    EXECUTE format(
      'CREATE POLICY open_all ON %I FOR ALL TO anon, authenticated
       USING (true) WITH CHECK (true)', t);
  END LOOP;
END$$;

-- Enable Supabase Realtime
DO $$
DECLARE
  t text;
  tables text[] := ARRAY['app_users', 'access_requests'];
BEGIN
  FOREACH t IN ARRAY tables LOOP
    EXECUTE format('ALTER TABLE %I REPLICA IDENTITY FULL', t);

    IF NOT EXISTS (
      SELECT 1 FROM pg_publication_tables
      WHERE pubname = 'supabase_realtime'
        AND schemaname = 'public'
        AND tablename = t
    ) THEN
      EXECUTE format(
        'ALTER PUBLICATION supabase_realtime ADD TABLE %I', t);
    END IF;
  END LOOP;
END$$;
