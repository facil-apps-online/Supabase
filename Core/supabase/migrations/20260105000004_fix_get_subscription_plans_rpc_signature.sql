-- Function: get_subscription_plans_for_tenant
DROP FUNCTION IF EXISTS public.get_subscription_plans_for_tenant(uuid);
CREATE OR REPLACE FUNCTION public.get_subscription_plans_for_tenant(p_tenant_id uuid, p_platform_id uuid)
RETURNS TABLE(
    plan_id uuid,
    plan_name text,
    plan_description text,
    plan_features text[],
    billing_frequency_months integer,
    price_id uuid,
    calculated_price numeric,
    calculated_extra_branch_price numeric,
    calculated_promotional_price numeric,
    currency_code text,
    currency_symbol text,
    base_price numeric,
    active_branches_count integer
) AS $$
DECLARE
    v_country_id UUID;
    v_active_branch_assets_count INT;
    v_current_subscription_id UUID;
BEGIN
    -- Derive country_id from tenants table, as it's still needed for pricing filter
    SELECT country_id INTO v_country_id FROM public.tenants WHERE id = p_tenant_id;
    
    IF v_country_id IS NULL THEN 
        RAISE EXCEPTION 'País no encontrado para el tenant: %', p_tenant_id; 
    END IF;
    -- platform_id is now passed as parameter, so no need to derive it

    SELECT id INTO v_current_subscription_id
    FROM public.tenant_subscriptions
    WHERE tenant_id = p_tenant_id
    ORDER BY end_date DESC NULLS FIRST
    LIMIT 1;

    IF v_current_subscription_id IS NOT NULL THEN
        SELECT count(*)::INT INTO v_active_branch_assets_count
        FROM public.subscription_assets
        WHERE tenant_subscription_id = v_current_subscription_id
          AND asset_type = 'branch'
          AND status = 'active';
    ELSE
        v_active_branch_assets_count := 0;
    END IF;

    RETURN QUERY
    SELECT
        gcp.plan_id,
        gcp.plan_name,
        gcp.plan_description,
        gcp.plan_features,
        gcp.billing_frequency_months,
        gcp.price_id,
        (gcp.calculated_price + (v_active_branch_assets_count * gcp.calculated_extra_branch_price)) AS calculated_price,
        gcp.calculated_extra_branch_price,
        gcp.calculated_promotional_price,
        gcp.currency_code,
        gcp.currency_symbol,
        gcp.calculated_price AS base_price,
        v_active_branch_assets_count AS active_branches_count
    FROM
        public.get_calculated_plan_prices(p_platform_id) gcp -- Use p_platform_id here
    WHERE
        gcp.country_id = v_country_id;
END;
$$ LANGUAGE plpgsql;
