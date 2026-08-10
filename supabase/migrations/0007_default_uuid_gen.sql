-- Bismillah Constructions — schema migration 0007.
--
-- Set default primary key generation to UUID v4 (`gen_random_uuid()`) for all
-- sync tables. Primary keys are client-generated in Dart via package:uuid (v4),
-- but setting a server-side default ensures any direct SQL inserts or server-side
-- scripts automatically receive globally unique UUID v4 primary keys.
--
-- Apply once via Supabase Dashboard -> SQL Editor. Idempotent — safe to re-run.

ALTER TABLE projects ALTER COLUMN id SET DEFAULT gen_random_uuid()::text;
ALTER TABLE suppliers ALTER COLUMN id SET DEFAULT gen_random_uuid()::text;
ALTER TABLE banks ALTER COLUMN id SET DEFAULT gen_random_uuid()::text;
ALTER TABLE counter_entities ALTER COLUMN id SET DEFAULT gen_random_uuid()::text;
ALTER TABLE journal_entries ALTER COLUMN id SET DEFAULT gen_random_uuid()::text;
ALTER TABLE material_inventory ALTER COLUMN id SET DEFAULT gen_random_uuid()::text;
ALTER TABLE material_types ALTER COLUMN id SET DEFAULT gen_random_uuid()::text;
ALTER TABLE labour_types ALTER COLUMN id SET DEFAULT gen_random_uuid()::text;
ALTER TABLE notes ALTER COLUMN id SET DEFAULT gen_random_uuid()::text;
ALTER TABLE follow_ups ALTER COLUMN id SET DEFAULT gen_random_uuid()::text;
