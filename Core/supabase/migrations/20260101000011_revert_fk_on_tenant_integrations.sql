-- This migration reverts the changes made in 20260101000010.
-- It removes the foreign key relationship between tenant_integrations and integration_providers
-- because some providers like 'google_drive' are handled virtually and do not exist in the integration_providers table.

-- 1. Drop the foreign key constraint
ALTER TABLE public.tenant_integrations
DROP CONSTRAINT IF EXISTS fk_tenant_integrations_provider;

-- 2. Drop the index
DROP INDEX IF EXISTS public.idx_tenant_integrations_provider_id;

-- 3. Drop the column
ALTER TABLE public.tenant_integrations
DROP COLUMN IF EXISTS provider_id;
