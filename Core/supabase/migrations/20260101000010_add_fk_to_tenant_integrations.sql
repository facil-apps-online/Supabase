-- 1. Add the new column, allowing NULLs for now
ALTER TABLE public.tenant_integrations
ADD COLUMN provider_id UUID;

-- 2. Backfill the new column using the existing text 'provider' field
-- This assumes that 'provider' in tenant_integrations matches 'slug' in integration_providers
UPDATE public.tenant_integrations ti
SET provider_id = ip.id
FROM public.integration_providers ip
WHERE ti.provider = ip.slug;

-- 3. Clean up orphaned integrations that couldn't be matched
-- This is important to allow setting the column to NOT NULL
DELETE FROM public.tenant_integrations
WHERE provider_id IS NULL;

-- 4. Add the foreign key constraint
ALTER TABLE public.tenant_integrations
ADD CONSTRAINT fk_tenant_integrations_provider
FOREIGN KEY (provider_id)
REFERENCES public.integration_providers(id)
ON DELETE CASCADE; -- Cascade is better, if a provider is deleted, its integrations are too.

-- 5. Make the column NOT NULL now that it's backfilled and cleaned
ALTER TABLE public.tenant_integrations
ALTER COLUMN provider_id SET NOT NULL;

-- 6. (Optional but recommended) Add an index for performance
CREATE INDEX IF NOT EXISTS idx_tenant_integrations_provider_id
ON public.tenant_integrations(provider_id);