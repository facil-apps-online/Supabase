-- Migration to fix subscription functions and add missing features column.
-- Version: 20251104000009

BEGIN;

-- Step 1: Add the missing 'features' column to plan_country_configurations
ALTER TABLE public.plan_country_configurations
ADD COLUMN IF NOT EXISTS features text[] NULL DEFAULT array[]::text[];

-- Step 2: Correct the get_calculated_plan_prices function to use the new features column
CREATE OR REPLACE FUNCTION public.get_calculated_plan_prices(p_platform_id uuid)
RETURNS TABLE(plan_id uuid, plan_name text, plan_description text, plan_features text[], billing_frequency_months integer, price_id uuid, base_price_cop numeric, extra_branch_price_cop numeric, country_id uuid, country_name text, calculated_price numeric, calculated_extra_branch_price numeric, calculated_promotional_price numeric, currency_code text, currency_symbol text)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    WITH
    branch_asset AS (
        SELECT id FROM public.plan_assets WHERE asset_key = 'suc_glam' LIMIT 1
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
        pcc.features AS plan_features, -- FIXED: Select features from plan_country_configurations
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
        cr.csymbol AS currency_symbol
    FROM
        public.subscription_plans sp
    CROSS JOIN country_rates cr
    LEFT JOIN public.plan_country_configurations pcc ON sp.id = pcc.plan_id AND cr.cid = pcc.country_id -- FIXED: Added join
    LEFT JOIN current_tariffs ct ON sp.id = ct.subscription_plan_id
    WHERE
        sp.is_active = TRUE
        AND sp.platform_id = p_platform_id
        AND sp.is_default_trial = false
    ORDER BY
        sp.display_order, cr.cname;
END;
$$;

-- Step 3: Correct the get_subscription_status_for_tenant function to use the correct joins
CREATE OR REPLACE FUNCTION public.get_subscription_status_for_tenant(p_tenant_id uuid)
RETURNS TABLE(status text, end_date text, plan_name text)
LANGUAGE plpgsql
AS $$
DECLARE
    v_subscription RECORD;
BEGIN
    -- Find the subscription with the most recent end date
    SELECT
        ts.end_date,
        ts.start_date,
        sp.name AS subscription_plan_name
    INTO
        v_subscription
    FROM
        public.tenant_subscriptions ts
    JOIN
        public.plan_country_configurations pcc ON ts.plan_country_configuration_id = pcc.id -- FIXED JOIN
    JOIN
        public.subscription_plans sp ON pcc.plan_id = sp.id -- FIXED JOIN
    WHERE
        ts.tenant_id = p_tenant_id
    ORDER BY
        ts.end_date DESC NULLS FIRST
    LIMIT 1;

    IF v_subscription IS NULL THEN
        RETURN QUERY SELECT 'cancelado'::text, NULL::text, NULL::text;
    ELSE
        RETURN QUERY
        SELECT
            CASE
                WHEN v_subscription.end_date IS NULL AND v_subscription.start_date <= NOW() THEN 'activo'::TEXT
                WHEN v_subscription.end_date IS NOT NULL AND NOW() BETWEEN v_subscription.start_date AND v_subscription.end_date THEN 'activo'::TEXT
                WHEN v_subscription.end_date IS NOT NULL AND NOW() BETWEEN v_subscription.end_date AND (v_subscription.end_date + '3 days'::interval) THEN 'gracia'::TEXT
                WHEN v_subscription.end_date IS NOT NULL AND NOW() > (v_subscription.end_date + '3 days'::interval) THEN 'suspendido'::TEXT
                ELSE 'cancelado'::TEXT
            END AS calculated_status,
            to_char(v_subscription.end_date, 'YYYY-MM-DD')::text,
            v_subscription.subscription_plan_name::text;
    END IF;
END;
$$;

-- Step 4: Re-include get_subscription_plans_for_tenant as it depends on the function above
CREATE OR REPLACE FUNCTION public.get_subscription_plans_for_tenant(p_tenant_id uuid)
RETURNS TABLE(plan_id uuid, plan_name text, plan_description text, plan_features text[], billing_frequency_months integer, price_id uuid, calculated_price numeric, calculated_extra_branch_price numeric, calculated_promotional_price numeric, currency_code text, currency_symbol text, base_price numeric, active_branches_count integer)
LANGUAGE plpgsql
AS $$
DECLARE
    v_country_id UUID;
    v_platform_id UUID;
    v_active_branch_assets_count INT;
    v_current_subscription_id UUID;
BEGIN
    SELECT country_id, platform_id INTO v_country_id, v_platform_id FROM public.tenants WHERE id = p_tenant_id;
    
    IF v_country_id IS NULL THEN 
        RAISE EXCEPTION 'País no encontrado para el tenant: %', p_tenant_id; 
    END IF;
    IF v_platform_id IS NULL THEN 
        RAISE EXCEPTION 'Plataforma no encontrada para el tenant: %', p_tenant_id; 
    END IF;

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
        public.get_calculated_plan_prices(v_platform_id) gcp
    WHERE
        gcp.country_id = v_country_id;
END;
$$;

COMMIT;
