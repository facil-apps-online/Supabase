-- 1. Add the is_visible_on_microsite column to the branches table.
ALTER TABLE public.branches
ADD COLUMN is_visible_on_microsite BOOLEAN NOT NULL DEFAULT false;

-- 2. Set the new flag to true for all existing active branches so they appear immediately.
UPDATE public.branches
SET is_visible_on_microsite = true
WHERE status = 'active';
