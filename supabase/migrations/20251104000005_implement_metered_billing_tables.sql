-- Migration to adapt tenant_subscriptions and add asset_usage_tracking for metered billing.
-- Version: 20251104000005

BEGIN;

-- Step 1: Drop constraints from tenant_subscriptions that depend on the old columns.
ALTER TABLE public.tenant_subscriptions DROP CONSTRAINT IF EXISTS tenant_subscriptions_subscription_plan_id_fkey;
ALTER TABLE public.tenant_subscriptions DROP CONSTRAINT IF EXISTS fk_active_plan;
ALTER TABLE public.tenant_subscriptions DROP CONSTRAINT IF EXISTS tenant_subscriptions_tenant_id_subscription_plan_id_start_d_key;

-- Step 2: Rename subscription_plan_id to plan_country_configuration_id
ALTER TABLE public.tenant_subscriptions RENAME COLUMN subscription_plan_id TO plan_country_configuration_id;

-- Step 3: Drop the now-redundant active_plan_id column
ALTER TABLE public.tenant_subscriptions DROP COLUMN IF EXISTS active_plan_id;

-- Step 4: Make the column nullable and clear its old values to prevent FK violation
-- This is a destructive change for existing subscriptions, which will need to be re-assigned.
ALTER TABLE public.tenant_subscriptions ALTER COLUMN plan_country_configuration_id DROP NOT NULL;
UPDATE public.tenant_subscriptions SET plan_country_configuration_id = NULL;

-- Step 5: Add the new foreign key constraint to plan_country_configurations
ALTER TABLE public.tenant_subscriptions
ADD CONSTRAINT tenant_subscriptions_plan_country_configuration_id_fkey
FOREIGN KEY (plan_country_configuration_id)
REFERENCES public.plan_country_configurations(id) ON DELETE RESTRICT;

-- Step 6: Re-add the unique constraint with the new column name. Note: Nulls are not considered unique.
ALTER TABLE public.tenant_subscriptions
ADD CONSTRAINT tenant_subscriptions_tenant_id_pcc_id_start_date_key
UNIQUE (tenant_id, plan_country_configuration_id, start_date);

-- Step 7: Create the new asset_usage_tracking table
CREATE TABLE public.asset_usage_tracking (
    id bigserial PRIMARY KEY,
    tenant_id uuid NOT NULL,
    asset_id uuid NOT NULL,
    usage_period_start date NOT NULL,
    usage_period_end date NOT NULL,
    quantity_used bigint NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT asset_usage_tracking_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE,
    CONSTRAINT asset_usage_tracking_asset_id_fkey FOREIGN KEY (asset_id) REFERENCES public.plan_assets(id) ON DELETE CASCADE,
    CONSTRAINT asset_usage_tracking_tenant_asset_period_unique UNIQUE (tenant_id, asset_id, usage_period_start)
);

COMMENT ON TABLE public.asset_usage_tracking IS 'Tracks metered usage of plan assets for each tenant per billing period.';

-- Step 8: Add audit triggers for the new table
create trigger audit_asset_usage_tracking_changes
after INSERT or DELETE or update on asset_usage_tracking for EACH row
execute FUNCTION audit_trigger_function ();

create trigger trigger_asset_usage_tracking_updated_at BEFORE
update on asset_usage_tracking for EACH row
execute FUNCTION update_updated_at_column ();

COMMIT;
