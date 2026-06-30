-- 1. Add 'scoping' column to plan_assets to differentiate between global and per-country assets
ALTER TABLE public.plan_assets
ADD COLUMN scoping TEXT NOT NULL DEFAULT 'global';

ALTER TABLE public.plan_assets
ADD CONSTRAINT check_scoping CHECK (scoping IN ('global', 'per_country'));

COMMENT ON COLUMN public.plan_assets.scoping IS 'Defines if the asset limit is global for the plan or defined per country. (global | per_country)';

-- 2. Rename the overrides table to reflect its new purpose as a primary limit table for per-country assets
ALTER TABLE public.plan_limit_country_overrides
RENAME TO plan_country_asset_limits;

-- 3. Update the comment on the renamed table
COMMENT ON TABLE public.plan_country_asset_limits IS 'Defines the limits for per-country assets within a subscription plan.';
