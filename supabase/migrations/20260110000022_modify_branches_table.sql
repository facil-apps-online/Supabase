-- Step 1: Add the new platform_id column, initially allowing NULLs
ALTER TABLE public.branches
ADD COLUMN platform_id UUID;

-- Step 2: Populate the new platform_id column from the corresponding tenants table
-- This assumes a tenants table exists in the same database with the platform_id
UPDATE public.branches b
SET platform_id = t.platform_id
FROM public.tenants t
WHERE b.tenant_id = t.id;

-- Step 3: Make the platform_id column non-nullable as it's now populated
ALTER TABLE public.branches
ALTER COLUMN platform_id SET NOT NULL;

-- Step 4: Add a UNIQUE constraint to enforce the desired key structure,
-- without breaking all existing foreign keys. The primary key remains on (id).
ALTER TABLE public.branches
ADD CONSTRAINT branches_id_tenant_id_platform_id_key UNIQUE (id, tenant_id, platform_id);