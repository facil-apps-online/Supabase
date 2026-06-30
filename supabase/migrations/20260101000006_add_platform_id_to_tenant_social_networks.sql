-- 1. Add the platform_id column to tenant_social_networks, allowing NULLs for now.
ALTER TABLE public.tenant_social_networks
ADD COLUMN platform_id UUID;

-- 2. Populate the new platform_id column from the tenants table.
-- This assumes the 'tenants' table still exists in this database and has the platform_id.
UPDATE public.tenant_social_networks AS tsn
SET platform_id = t.platform_id
FROM public.tenants AS t
WHERE tsn.tenant_id = t.id;

-- 3. Alter the column to be NOT NULL after populating it.
ALTER TABLE public.tenant_social_networks
ALTER COLUMN platform_id SET NOT NULL;
