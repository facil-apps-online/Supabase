-- Migration to reintroduce the plan_asset_bonuses table for the country-centric model.
-- Version: 20251104000004

CREATE TABLE public.plan_asset_bonuses (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    source_asset_limit_id uuid NOT NULL,
    bonus_asset_id uuid NOT NULL,
    quantity integer NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT plan_asset_bonuses_pkey PRIMARY KEY (id),
    CONSTRAINT plan_asset_bonuses_source_limit_fkey FOREIGN KEY (source_asset_limit_id) REFERENCES public.plan_asset_limits(id) ON DELETE CASCADE,
    CONSTRAINT plan_asset_bonuses_bonus_asset_fkey FOREIGN KEY (bonus_asset_id) REFERENCES public.plan_assets(id) ON DELETE CASCADE
);

COMMENT ON TABLE public.plan_asset_bonuses IS 'Defines bonuses granted by purchasing extra units of a specific asset within a plan-country configuration.';

-- Add a check to ensure quantity is positive
ALTER TABLE public.plan_asset_bonuses
ADD CONSTRAINT quantity_must_be_positive CHECK (quantity > 0);

-- Add triggers
create trigger audit_plan_asset_bonuses_changes
after INSERT or DELETE or update on plan_asset_bonuses for EACH row
execute FUNCTION audit_trigger_function ();

create trigger trigger_plan_asset_bonuses_updated_at BEFORE
update on plan_asset_bonuses for EACH row
execute FUNCTION update_updated_at_column ();
