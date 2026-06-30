-- 1. Create the new table for multiple bonuses per asset
CREATE TABLE public.plan_asset_bonuses (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    source_limit_id uuid NOT NULL,
    bonus_asset_id uuid NOT NULL,
    quantity numeric NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT plan_asset_bonuses_pkey PRIMARY KEY (id),
    CONSTRAINT plan_asset_bonuses_source_limit_id_fkey FOREIGN KEY (source_limit_id) REFERENCES public.plan_asset_limits(id) ON DELETE CASCADE,
    CONSTRAINT plan_asset_bonuses_bonus_asset_id_fkey FOREIGN KEY (bonus_asset_id) REFERENCES public.plan_assets(id) ON DELETE CASCADE
);

COMMENT ON TABLE public.plan_asset_bonuses IS 'Allows an asset limit (e.g., buying a branch) to grant multiple bonuses (e.g., extra space, extra invoices).';
COMMENT ON COLUMN public.plan_asset_bonuses.source_limit_id IS 'The plan_asset_limit that triggers this bonus.';
COMMENT ON COLUMN public.plan_asset_bonuses.bonus_asset_id IS 'The plan_asset that is granted as a bonus.';
COMMENT ON COLUMN public.plan_asset_bonuses.quantity IS 'The amount of the bonus asset granted.';

-- Enable RLS
ALTER TABLE public.plan_asset_bonuses ENABLE ROW LEVEL SECURITY;

-- 2. Create the new table for country-specific limit overrides
CREATE TABLE public.plan_limit_country_overrides (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    plan_asset_limit_id uuid NOT NULL,
    country_id uuid NOT NULL,
    value text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT plan_limit_country_overrides_pkey PRIMARY KEY (id),
    CONSTRAINT plan_limit_country_overrides_plan_asset_limit_id_fkey FOREIGN KEY (plan_asset_limit_id) REFERENCES public.plan_asset_limits(id) ON DELETE CASCADE,
    CONSTRAINT plan_limit_country_overrides_country_id_fkey FOREIGN KEY (country_id) REFERENCES public.countries(id) ON DELETE CASCADE,
    CONSTRAINT unique_override_for_limit_and_country UNIQUE (plan_asset_limit_id, country_id)
);

COMMENT ON TABLE public.plan_limit_country_overrides IS 'Defines exceptions to the default limits of a plan asset for specific countries.';
COMMENT ON COLUMN public.plan_limit_country_overrides.plan_asset_limit_id IS 'The default limit being overridden.';
COMMENT ON COLUMN public.plan_limit_country_overrides.country_id IS 'The country where this override applies.';
COMMENT ON COLUMN public.plan_limit_country_overrides.value IS 'The new limit value for the specified country. Can be numeric or a special value like "unlimited".';

-- Enable RLS
ALTER TABLE public.plan_limit_country_overrides ENABLE ROW LEVEL SECURITY;

-- 3. Drop the old, now-redundant columns from plan_asset_limits
ALTER TABLE public.plan_asset_limits
DROP COLUMN IF EXISTS bonus_on_extra,
DROP COLUMN IF EXISTS country_id;
