-- Bismillah Constructions — schema migration 0003.
--
-- Local schema v18: a Labour-Rate project's service fee can now be a flat
-- rupee amount instead of only a percentage of spend. Two new columns on
-- `projects` mirror the SQLite change so both sides of the sync agree:
--
--   * service_fee_type   — 'percent' | 'fixed' (defaults to 'percent' so
--                          existing rows keep their old behaviour).
--   * service_fee_amount — the flat fee in rupees when type = 'fixed'.
--
-- Apply this once via Supabase Dashboard → SQL Editor → New Query BEFORE
-- the next sync from an updated app build. Idempotent — safe to re-run.

ALTER TABLE projects
  ADD COLUMN IF NOT EXISTS service_fee_type text NOT NULL DEFAULT 'percent';

ALTER TABLE projects
  ADD COLUMN IF NOT EXISTS service_fee_amount numeric;
