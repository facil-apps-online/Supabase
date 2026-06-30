-- Migration #12: Adjust Core Schema for Multi-Platform and Tenant-Specific Roles
-- This script applies the architectural changes discussed to make the schema more robust.

BEGIN;

-- ========= Step 1: Modify `roles` table =========
-- Add nullable tenant_id and platform_id to support system, platform, and tenant custom roles.
ALTER TABLE "public"."roles" ADD COLUMN IF NOT EXISTS "tenant_id" UUID NULL;
ALTER TABLE "public"."roles" ADD COLUMN IF NOT EXISTS "platform_id" UUID NULL;

-- Add foreign key constraints for the new columns
ALTER TABLE "public"."roles" ADD CONSTRAINT "roles_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;
ALTER TABLE "public"."roles" ADD CONSTRAINT "roles_platform_id_fkey" FOREIGN KEY (platform_id) REFERENCES public.platforms(id) ON DELETE CASCADE;


-- ========= Step 2: Add `platform_id` to tenant-specific core tables =========
-- This enforces the "golden rule": any table with a tenant_id also gets a platform_id for namespacing.
ALTER TABLE public.asset_usage_tracking ADD COLUMN IF NOT EXISTS platform_id UUID;
ALTER TABLE public.email_logs ADD COLUMN IF NOT EXISTS platform_id UUID;
-- email_templates already has platform_id for master templates, but tenant-specific ones need it. We'll handle this by joining through tenants.
ALTER TABLE public.error_logs ADD COLUMN IF NOT EXISTS platform_id UUID;
ALTER TABLE public.integration_record ADD COLUMN IF NOT EXISTS platform_id UUID;
ALTER TABLE public.monthly_charges ADD COLUMN IF NOT EXISTS platform_id UUID;
ALTER TABLE public.payment_intents ADD COLUMN IF NOT EXISTS platform_id UUID;
ALTER TABLE public.payments ADD COLUMN IF NOT EXISTS platform_id UUID;
ALTER TABLE public.subscription_assets ADD COLUMN IF NOT EXISTS platform_id UUID;
ALTER TABLE public.subscription_items ADD COLUMN IF NOT EXISTS platform_id UUID;
ALTER TABLE public.tenant_integrations ADD COLUMN IF NOT EXISTS platform_id UUID;
ALTER TABLE public.tenant_settings ADD COLUMN IF NOT EXISTS platform_id UUID;
ALTER TABLE public.tenant_subscriptions ADD COLUMN IF NOT EXISTS platform_id UUID;
ALTER TABLE public.tenant_template_settings ADD COLUMN IF NOT EXISTS platform_id UUID;
ALTER TABLE public.vendor_tenants ADD COLUMN IF NOT EXISTS platform_id UUID;


-- ========= Step 3: Adjust `translations` table =========
-- Make it platform-specific instead of tenant-specific.
ALTER TABLE public.translations DROP COLUMN IF EXISTS tenant_id;
ALTER TABLE public.translations ADD COLUMN IF NOT EXISTS platform_id UUID;
ALTER TABLE public.translations ADD CONSTRAINT "translations_platform_id_fkey" FOREIGN KEY (platform_id) REFERENCES public.platforms(id) ON DELETE CASCADE;


-- ========= Step 4: Backfill `platform_id` in all modified tables =========
-- This assumes tenant data will be migrated before this script is run in a real data migration scenario.
-- For now, this prepares the schema for that eventuality. The UPDATEs will run on any existing data.

UPDATE public.asset_usage_tracking t SET platform_id = (SELECT platform_id FROM public.tenants WHERE t.tenant_id = tenants.id) WHERE t.platform_id IS NULL;
UPDATE public.email_logs t SET platform_id = (SELECT platform_id FROM public.tenants WHERE t.tenant_id = tenants.id) WHERE t.platform_id IS NULL;
UPDATE public.error_logs t SET platform_id = (SELECT platform_id FROM public.tenants WHERE t.tenant_id = tenants.id) WHERE t.platform_id IS NULL;
UPDATE public.integration_record t SET platform_id = (SELECT platform_id FROM public.tenants WHERE t.tenant_id = tenants.id) WHERE t.platform_id IS NULL;
UPDATE public.monthly_charges t SET platform_id = (SELECT platform_id FROM public.tenants WHERE t.tenant_id = tenants.id) WHERE t.platform_id IS NULL;
UPDATE public.payment_intents t SET platform_id = (SELECT platform_id FROM public.tenants WHERE t.tenant_id = tenants.id) WHERE t.platform_id IS NULL;
UPDATE public.payments t SET platform_id = (SELECT platform_id FROM public.tenants WHERE t.tenant_id = tenants.id) WHERE t.platform_id IS NULL;
UPDATE public.tenant_integrations t SET platform_id = (SELECT platform_id FROM public.tenants WHERE t.tenant_id = tenants.id) WHERE t.platform_id IS NULL;
UPDATE public.tenant_settings t SET platform_id = (SELECT platform_id FROM public.tenants WHERE t.tenant_id = tenants.id) WHERE t.platform_id IS NULL;
UPDATE public.tenant_subscriptions t SET platform_id = (SELECT platform_id FROM public.tenants WHERE t.tenant_id = tenants.id) WHERE t.platform_id IS NULL;
UPDATE public.tenant_template_settings t SET platform_id = (SELECT platform_id FROM public.tenants WHERE t.tenant_id = tenants.id) WHERE t.platform_id IS NULL;
UPDATE public.vendor_tenants t SET platform_id = (SELECT platform_id FROM public.tenants WHERE t.tenant_id = tenants.id) WHERE t.platform_id IS NULL;

-- Backfill for tables related via tenant_subscriptions
UPDATE public.subscription_assets sa SET platform_id = ts.platform_id
FROM public.tenant_subscriptions ts
WHERE sa.tenant_subscription_id = ts.id AND sa.platform_id IS NULL;

UPDATE public.subscription_items si SET platform_id = ts.platform_id
FROM public.tenant_subscriptions ts
WHERE si.subscription_id = ts.id AND si.platform_id IS NULL;


-- ========= Step 5: Apply NOT NULL constraints now that data is backfilled =========

ALTER TABLE public.asset_usage_tracking ALTER COLUMN platform_id SET NOT NULL;
ALTER TABLE public.email_logs ALTER COLUMN platform_id SET NOT NULL;
-- error_logs platform_id can be null if tenant_id is null
ALTER TABLE public.monthly_charges ALTER COLUMN platform_id SET NOT NULL;
ALTER TABLE public.payment_intents ALTER COLUMN platform_id SET NOT NULL;
ALTER TABLE public.payments ALTER COLUMN platform_id SET NOT NULL;
ALTER TABLE public.subscription_assets ALTER COLUMN platform_id SET NOT NULL;
ALTER TABLE public.subscription_items ALTER COLUMN platform_id SET NOT NULL;
ALTER TABLE public.tenant_integrations ALTER COLUMN platform_id SET NOT NULL;
ALTER TABLE public.tenant_settings ALTER COLUMN platform_id SET NOT NULL;
ALTER TABLE public.tenant_subscriptions ALTER COLUMN platform_id SET NOT NULL;
ALTER TABLE public.tenant_template_settings ALTER COLUMN platform_id SET NOT NULL;
ALTER TABLE public.vendor_tenants ALTER COLUMN platform_id SET NOT NULL;
-- platform_id in translations can be null
-- platform_id in roles can be null

COMMIT;
