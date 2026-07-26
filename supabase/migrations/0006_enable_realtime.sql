-- Bismillah Constructions — schema migration 0006.
--
-- Enable Supabase Realtime on every synced table. The app subscribes to
-- Postgres change events per table (filtered by tenant_id) so an edit on one
-- device streams to every other device within ~1 second, instead of waiting
-- for the periodic poll. Without this step the app still works — it just falls
-- back to its 30-second safety poll for inbound changes.
--
-- Two parts:
--   1. REPLICA IDENTITY FULL so UPDATE/DELETE events carry the full row (the
--      tenant_id filter and soft-delete propagation need every column, not
--      just the primary key). Cheap here — these tables are small.
--   2. Add each table to the built-in `supabase_realtime` publication. Guarded
--      so re-running is a no-op (adding an already-published table errors).
--
-- Apply once via Supabase Dashboard -> SQL Editor. Idempotent. RLS is already
-- open (migration 0001), so the anon key may subscribe.

DO $$
DECLARE
  t text;
  tables text[] := ARRAY[
    'projects','suppliers','banks','counter_entities','journal_entries',
    'material_inventory','material_types','labour_types','notes','follow_ups'
  ];
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
