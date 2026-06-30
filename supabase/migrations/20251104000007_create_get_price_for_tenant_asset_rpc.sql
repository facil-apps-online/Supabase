-- Migration to create the RPC function for getting asset prices with country-specific logic.
-- Version: 20251104000007

BEGIN;

-- Define a reusable type for the function's return value
CREATE TYPE public.price_info AS (
    price numeric,
    currency_code text,
    currency_symbol text,
    source_country text
);

-- Create the main function
CREATE OR REPLACE FUNCTION public.get_price_for_tenant_asset(
    p_tenant_id uuid,
    p_asset_key text
)
RETURNS public.price_info
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_price_info public.price_info;
    v_asset_id uuid;
    v_tenant_country_id uuid;
    v_plan_id uuid;
    v_plan_country_config_id uuid;
    v_colombia_country_id uuid;
    v_colombian_plan_country_config_id uuid;
BEGIN
    -- 1. Get Asset ID from key
    SELECT id INTO v_asset_id FROM public.plan_assets WHERE asset_key = p_asset_key LIMIT 1;
    IF v_asset_id IS NULL THEN
        RAISE EXCEPTION 'Asset with key % not found', p_asset_key;
    END IF;

    -- 2. Get Tenant's active subscription, plan, and country
    SELECT ts.plan_country_configuration_id, pcc.plan_id, t.country_id
    INTO v_plan_country_config_id, v_plan_id, v_tenant_country_id
    FROM public.tenant_subscriptions ts
    JOIN public.tenants t ON ts.tenant_id = t.id
    JOIN public.plan_country_configurations pcc ON ts.plan_country_configuration_id = pcc.id
    WHERE ts.tenant_id = p_tenant_id AND ts.is_active = TRUE
    LIMIT 1;

    IF v_plan_country_config_id IS NULL THEN
        -- Return null or a default structure if no active subscription is found
        v_price_info := (0, 'USD', '$', 'None');
        RETURN v_price_info;
    END IF;

    -- 3. Look for a price in the tenant's specific country configuration
    SELECT pal.overage_unit_price, c.code, c.symbol, co.name
    INTO v_price_info.price, v_price_info.currency_code, v_price_info.currency_symbol, v_price_info.source_country
    FROM public.plan_asset_limits pal
    JOIN public.plan_country_configurations pcc ON pal.plan_country_config_id = pcc.id
    JOIN public.countries co ON pcc.country_id = co.id
    JOIN public.currencies c ON co.default_currency_id = c.id
    WHERE pal.plan_country_config_id = v_plan_country_config_id
      AND pal.asset_id = v_asset_id
      AND pal.overage_unit_price IS NOT NULL
      AND pal.overage_unit_price > 0;

    -- 4. If found, return it
    IF v_price_info.price IS NOT NULL THEN
        RETURN v_price_info;
    END IF;

    -- 5. If not found, look for the Colombian price for the same plan
    SELECT id INTO v_colombia_country_id FROM public.countries WHERE iso_code = 'CO' LIMIT 1;
    IF v_colombia_country_id IS NULL THEN
        RAISE EXCEPTION 'Country configuration for Colombia (CO) not found.';
    END IF;

    SELECT id INTO v_colombian_plan_country_config_id
    FROM public.plan_country_configurations
    WHERE plan_id = v_plan_id AND country_id = v_colombia_country_id;

    IF v_colombian_plan_country_config_id IS NULL THEN
        -- If no specific Colombian config, return null or default
        v_price_info := (0, 'USD', '$', 'None');
        RETURN v_price_info;
    END IF;

    SELECT pal.overage_unit_price, 'COP', '$', 'Colombia'
    INTO v_price_info.price, v_price_info.currency_code, v_price_info.currency_symbol, v_price_info.source_country
    FROM public.plan_asset_limits pal
    WHERE pal.plan_country_config_id = v_colombian_plan_country_config_id
      AND pal.asset_id = v_asset_id
      AND pal.overage_unit_price IS NOT NULL;

    -- 6. Return the Colombian price (or null if not found)
    RETURN v_price_info;

END;
$$;

COMMIT;
