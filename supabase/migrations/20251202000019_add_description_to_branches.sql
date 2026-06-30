ALTER TABLE public.branches
ADD COLUMN description TEXT NULL;

COMMENT ON COLUMN public.branches.description IS 'A public description of the branch, visible on the tenant''s microsite.';
