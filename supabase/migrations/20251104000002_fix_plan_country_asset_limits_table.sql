-- 1. Drop the incorrectly structured table.
-- The table was renamed from plan_limit_country_overrides, but its internal structure is wrong.
DROP TABLE IF EXISTS public.plan_country_asset_limits;

-- 2. Re-create the table with the correct structure.
CREATE TABLE public.plan_country_asset_limits (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    plan_id uuid NOT NULL,
    asset_id uuid NOT NULL,
    country_id uuid NOT NULL,
    value text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT plan_country_asset_limits_pkey PRIMARY KEY (id),
    CONSTRAINT plan_country_asset_limits_plan_id_fkey FOREIGN KEY (plan_id) REFERENCES public.subscription_plans(id) ON DELETE CASCADE,
    CONSTRAINT plan_country_asset_limits_asset_id_fkey FOREIGN KEY (asset_id) REFERENCES public.plan_assets(id) ON DELETE CASCADE,
    CONSTRAINT plan_country_asset_limits_country_id_fkey FOREIGN KEY (country_id) REFERENCES public.countries(id) ON DELETE CASCADE,
    CONSTRAINT unique_country_asset_for_plan UNIQUE (plan_id, asset_id, country_id)
);

COMMENT ON TABLE public.plan_country_asset_limits IS 'Defines the limits for per-country assets within a subscription plan.';
