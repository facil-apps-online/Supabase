-- Step 1: Drop the existing incorrect unique constraint
ALTER TABLE public.tenants DROP CONSTRAINT unique_country_slug;

-- Step 2: Add the new correct unique constraint that includes platform_id
ALTER TABLE public.tenants ADD CONSTRAINT unique_platform_country_slug UNIQUE (platform_id, country_id, slug);

COMMENT ON CONSTRAINT unique_platform_country_slug ON public.tenants IS 'Ensures the tenant slug is unique per country and per platform.';
