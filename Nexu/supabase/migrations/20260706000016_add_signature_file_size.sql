-- ==============================================================
-- Add file_size to signatures table
-- ==============================================================

ALTER TABLE public.signatures ADD COLUMN IF NOT EXISTS file_size integer;
