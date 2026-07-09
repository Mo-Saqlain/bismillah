-- Bismillah Constructions — schema migration 0004.
--
-- Local schema v19: projects can store a client WhatsApp number, used for
-- the post-transaction "send a confirmation" prompt on money received from
-- a project. Suppliers reuse their existing `phone` column, so only the
-- `projects` table needs a new field to keep both sides of the sync aligned.
--
-- Apply this once via Supabase Dashboard → SQL Editor → New Query BEFORE the
-- next sync from an updated app build. Idempotent — safe to re-run. Apply
-- 0003 first if you haven't.

ALTER TABLE projects
  ADD COLUMN IF NOT EXISTS whatsapp text;
