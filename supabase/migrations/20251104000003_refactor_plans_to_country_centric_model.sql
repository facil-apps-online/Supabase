-- Migration to refactor the subscription plan model to be country-centric.
-- Version: 20251104000003

-- Step 1: Drop tables that are now obsolete.
-- plan_asset_bonuses is no longer needed as the bonus concept is removed for simplification.
DROP TABLE IF EXISTS public.plan_asset_bonuses;
-- plan_country_asset_limits is replaced by the new structure.
DROP TABLE IF EXISTS public.plan_country_asset_limits;

-- Step 2: Create the new central configuration table 'plan_country_configurations'.
-- This table will hold the specific configuration of a plan for a given country.
CREATE TABLE public.plan_country_configurations (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    plan_id uuid NOT NULL,
    country_id uuid NOT NULL,
    is_active boolean NOT NULL DEFAULT true,
    features text[] NULL DEFAULT array[]::text[],
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT plan_country_configurations_pkey PRIMARY KEY (id),
    CONSTRAINT plan_country_configurations_plan_id_fkey FOREIGN KEY (plan_id) REFERENCES public.subscription_plans(id) ON DELETE CASCADE,
    CONSTRAINT plan_country_configurations_country_id_fkey FOREIGN KEY (country_id) REFERENCES public.countries(id) ON DELETE CASCADE,
    CONSTRAINT plan_country_configurations_unique UNIQUE (plan_id, country_id)
);
COMMENT ON TABLE public.plan_country_configurations IS 'Stores country-specific configurations for a subscription plan, including features and activation status.';

-- Step 3: Remove the 'features' column from 'subscription_plans' as it has been moved to the new table.
ALTER TABLE public.subscription_plans
DROP COLUMN IF EXISTS features;

-- Step 4: Remove the 'scoping' column from 'plan_assets' as the concept is no longer used.
ALTER TABLE public.plan_assets
DROP COLUMN IF EXISTS scoping;

-- Step 5: Re-structure 'plan_asset_limits' to link to the new configuration table.
-- We drop the old table and create a new one with the correct foreign key.
DROP TABLE IF EXISTS public.plan_asset_limits;
CREATE TABLE public.plan_asset_limits (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    plan_country_config_id uuid NOT NULL,
    asset_id uuid NOT NULL,
    value text NOT NULL,
    extra_unit_price numeric(10, 4) NOT NULL DEFAULT 0,
    overage_unit_price numeric(10, 4) NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT plan_asset_limits_pkey PRIMARY KEY (id),
    CONSTRAINT plan_asset_limits_config_id_fkey FOREIGN KEY (plan_country_config_id) REFERENCES public.plan_country_configurations(id) ON DELETE CASCADE,
    CONSTRAINT plan_asset_limits_asset_id_fkey FOREIGN KEY (asset_id) REFERENCES public.plan_assets(id) ON DELETE CASCADE,
    CONSTRAINT plan_asset_limits_unique_asset_per_config UNIQUE (plan_country_config_id, asset_id)
);
COMMENT ON TABLE public.plan_asset_limits IS 'Stores the limits and pricing for each asset within a specific plan-country configuration.';

-- Step 6: Add triggers for the new tables
create trigger audit_plan_country_configurations_changes
after INSERT or DELETE or update on plan_country_configurations for EACH row
execute FUNCTION audit_trigger_function ();

create trigger trigger_plan_country_configurations_updated_at BEFORE
update on plan_country_configurations for EACH row
execute FUNCTION update_updated_at_column ();

create trigger audit_plan_asset_limits_changes
after INSERT or DELETE or update on plan_asset_limits for EACH row
execute FUNCTION audit_trigger_function ();

create trigger trigger_plan_asset_limits_updated_at BEFORE
update on plan_asset_limits for EACH row
execute FUNCTION update_updated_at_column ();
