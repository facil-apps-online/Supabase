ALTER TABLE public.branches
ADD COLUMN google_place_id TEXT;

COMMENT ON COLUMN public.branches.google_place_id IS 'The Google Place ID for the branch, used for generating review links.';
