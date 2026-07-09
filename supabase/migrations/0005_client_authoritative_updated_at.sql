-- Bismillah Constructions — schema migration 0005.
--
-- Switch cloud sync to last-write-wins with a CLIENT-authoritative
-- `updated_at`. The app now overwrites a local row on pull only when the
-- server row's `updated_at` is strictly newer, so edits and soft-deletes
-- propagate across devices while staying offline-capable.
--
-- For that to be safe we must stop Postgres from auto-bumping `updated_at`
-- on every write: otherwise a device re-pushing a row it just pulled would
-- trigger a fresh server timestamp, which the other device pulls, re-pushes,
-- and so on — an endless timestamp ping-pong. With the trigger gone, the
-- server stores exactly the timestamp the writing device set, so a
-- redundant re-push is a harmless no-op.
--
-- Apply once via Supabase Dashboard -> SQL Editor. Idempotent.
--
-- NOTE: after this, editing a row directly in the Supabase table editor will
-- NOT advance its `updated_at`, so such a manual edit won't sync down to
-- devices. Normal app-driven writes are unaffected (the app sets the
-- timestamp itself). If you ever hand-edit a row and want it to sync, bump
-- its `updated_at` in the same statement.

DO $$
DECLARE
  t text;
  tables text[] := ARRAY[
    'projects','suppliers','banks','counter_entities','journal_entries',
    'material_inventory','material_types','labour_types','notes','follow_ups'
  ];
BEGIN
  FOREACH t IN ARRAY tables LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_bump_updated ON %I', t);
  END LOOP;
END$$;

DROP FUNCTION IF EXISTS bump_updated_at();
