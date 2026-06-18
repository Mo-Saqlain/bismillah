-- 0002: make material_inventory.quantity / .rate nullable.
--
-- Mirrors local schema v17. A material buy can now be logged without a
-- quantity — such rows carry a null rate and are excluded from the Material
-- Price Trend; their detail lives in the transaction memo instead.
--
-- Apply this in the Supabase SQL Editor on an EXISTING project. Fresh
-- projects created from 0001_initial.sql already have the nullable columns.

ALTER TABLE material_inventory ALTER COLUMN quantity DROP NOT NULL;
ALTER TABLE material_inventory ALTER COLUMN rate DROP NOT NULL;
