ALTER TABLE public.tenants
ADD COLUMN description TEXT NULL;

COMMENT ON COLUMN public.tenants.description IS 'A public description of the tenant, visible on their microsite.';
