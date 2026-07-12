-- ==============================================================
-- Add photo_size to employees table
-- ==============================================================

ALTER TABLE public.employees ADD COLUMN IF NOT EXISTS photo_size integer;
