-- Step 1: Add the platform_id column, allowing NULLs for now
ALTER TABLE public.tenant_settings
ADD COLUMN platform_id uuid;

-- Step 2: Populate the new platform_id column for existing rows
-- This is critical to avoid the "null value in column" error when adding the primary key.
UPDATE public.tenant_settings ts
SET platform_id = (
  SELECT t.platform_id
  FROM public.tenants t
  WHERE t.id = ts.tenant_id
)
WHERE ts.platform_id IS NULL;

-- Step 3: Now that the column is populated, make it NOT NULL
ALTER TABLE public.tenant_settings
ALTER COLUMN platform_id SET NOT NULL;

-- Step 4: Drop the old primary key constraint
ALTER TABLE public.tenant_settings
DROP CONSTRAINT tenant_settings_pkey;

-- Step 5: Add the new composite primary key constraint
ALTER TABLE public.tenant_settings
ADD CONSTRAINT tenant_settings_pkey PRIMARY KEY (tenant_id, platform_id);