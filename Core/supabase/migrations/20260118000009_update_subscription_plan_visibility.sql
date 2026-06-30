-- Actualizar visibilidad de planes de suscripción
-- 1. Actualizar get_calculated_plan_prices para incluir flag de Trial
DROP FUNCTION IF EXISTS public.get_calculated_plan_prices(uuid);

CREATE OR REPLACE FUNCTION public.get_calculated_plan_prices(p_platform_id uuid)
 RETURNS TABLE(
    plan_id uuid, 
    plan_name text, 
    plan_description text, 
    plan_features text[], 
    billing_frequency_months integer, 
    price_id uuid, 
    base_price_cop numeric, 
    extra_branch_price_cop numeric, 
    country_id uuid, 
    country_name text, 
    calculated_price numeric, 
    calculated_extra_branch_price numeric, 
    calculated_promotional_price numeric, 
    currency_code text, 
    currency_symbol text,
    is_default_trial boolean -- Nueva columna para filtrar en la función superior
 )
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN QUERY
    WITH
    branch_asset AS (
        SELECT pa.id
        FROM public.plan_assets pa
        JOIN public.asset_purposes ap ON pa.asset_purpose_id = ap.id
        WHERE pa.platform_id = p_platform_id AND ap.purpose_key = 'extra_branch'
        LIMIT 1
    ),
    current_tariffs AS (
        SELECT DISTINCT ON (pt.subscription_plan_id)
            pt.id AS tariff_id,
            pt.subscription_plan_id,
            pt.base_price,
            pt.promotional_price,
            c.code AS base_currency_code,
            (SELECT tap.extra_unit_price
             FROM public.tariff_asset_prices tap
             WHERE tap.tariff_id = pt.id AND tap.asset_id = (SELECT id FROM branch_asset)
             LIMIT 1) AS extra_branch_price
        FROM public.price_tariffs pt
        JOIN public.currencies c ON pt.currency_id = c.id
        WHERE pt.effective_date <= CURRENT_DATE
        ORDER BY pt.subscription_plan_id, pt.effective_date DESC
    ),
    country_rates AS (
        SELECT
            c.id AS cid, c.name AS cname, curr.code AS ccode, curr.symbol AS csymbol,
            er.rate AS usd_to_target_rate
        FROM public.countries c
        JOIN public.currencies curr ON c.default_currency_id = curr.id
        LEFT JOIN public.exchange_rates er ON er.target_currency_code = curr.code AND er.base_currency_code = 'USD'
        WHERE c.is_active = TRUE
    ),
    rates_to_usd AS (
        SELECT base_currency_code, rate FROM public.exchange_rates WHERE target_currency_code = 'USD'
        UNION ALL SELECT 'USD' AS base_currency_code, 1.0 AS rate
    )
    SELECT
        sp.id AS plan_id,
        sp.name AS plan_name,
        sp.description AS plan_description,
        COALESCE(pcc.features, ARRAY[]::text[]) AS plan_features,
        sp.billing_frequency_months,
        ct.tariff_id AS price_id,
        ct.base_price AS base_price_cop,
        COALESCE(ct.extra_branch_price, 0) AS extra_branch_price_cop,
        cr.cid AS country_id,
        cr.cname AS country_name,
        
        CASE
            WHEN ct.base_currency_code = cr.ccode THEN ct.base_price
            ELSE floor(ct.base_price * (SELECT rate FROM rates_to_usd WHERE base_currency_code = ct.base_currency_code LIMIT 1) * cr.usd_to_target_rate) + 0.99
        END AS calculated_price,

        CASE
            WHEN ct.base_currency_code = cr.ccode THEN COALESCE(ct.extra_branch_price, 0)
            ELSE floor(COALESCE(ct.extra_branch_price, 0) * (SELECT rate FROM rates_to_usd WHERE base_currency_code = ct.base_currency_code LIMIT 1) * cr.usd_to_target_rate) + 0.99
        END AS calculated_extra_branch_price,

        CASE
            WHEN ct.base_currency_code = cr.ccode THEN COALESCE(ct.promotional_price, 0)
            ELSE floor(COALESCE(ct.promotional_price, 0) * (SELECT rate FROM rates_to_usd WHERE base_currency_code = ct.base_currency_code LIMIT 1) * cr.usd_to_target_rate) + 0.99
        END AS calculated_promotional_price,

        cr.ccode AS currency_code,
        cr.csymbol AS currency_symbol,
        sp.is_default_trial
    FROM
        public.subscription_plans sp
    CROSS JOIN country_rates cr
    LEFT JOIN public.plan_country_configurations pcc ON sp.id = pcc.plan_id AND cr.cid = pcc.country_id
    LEFT JOIN current_tariffs ct ON sp.id = ct.subscription_plan_id
    WHERE
        sp.is_active = TRUE
        AND sp.platform_id = p_platform_id
    ORDER BY
        sp.display_order, cr.cname;
END;
$function$;

-- 2. Actualizar get_subscription_plans_for_tenant para filtrar trial si ya tuvo plan
DROP FUNCTION IF EXISTS public.get_subscription_plans_for_tenant(uuid, uuid);

CREATE OR REPLACE FUNCTION public.get_subscription_plans_for_tenant(p_tenant_id uuid, p_platform_id uuid)
 RETURNS TABLE(plan_id uuid, plan_name text, plan_description text, plan_features text[], billing_frequency_months integer, price_id uuid, calculated_price numeric, calculated_extra_branch_price numeric, calculated_promotional_price numeric, currency_code text, currency_symbol text, base_price numeric, active_branches_count integer)
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_country_id UUID;
    v_active_branch_assets_count INT;
    v_current_subscription_id UUID;
    v_has_had_subscription BOOLEAN;
BEGIN
    -- Derivar country_id
    SELECT country_id INTO v_country_id FROM public.tenants WHERE id = p_tenant_id;
    
    IF v_country_id IS NULL THEN 
        RAISE EXCEPTION 'País no encontrado para el tenant: %', p_tenant_id; 
    END IF;

    -- Verificar si el tenant ya tuvo o tiene alguna suscripción
    SELECT EXISTS (
        SELECT 1 FROM public.tenant_subscriptions WHERE tenant_id = p_tenant_id
    ) INTO v_has_had_subscription;

    -- Obtener la suscripción actual para conteo de activos
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
        public.get_calculated_plan_prices(p_platform_id) gcp
    WHERE
        gcp.country_id = v_country_id
        -- Regla: Si ya tuvo suscripción, ocultar los planes marcados como trial
        AND (NOT v_has_had_subscription OR gcp.is_default_trial = FALSE);
END;
$function$;
