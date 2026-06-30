-- Migration to fix platform isolation bugs in pricing and status RPC functions.
-- Version: 20251104000014

BEGIN;

-- Step 1: Correct get_calculated_plan_prices to be platform-aware
CREATE OR REPLACE FUNCTION public.get_calculated_plan_prices(p_platform_id uuid)
RETURNS TABLE(plan_id uuid, plan_name text, plan_description text, plan_features text[], billing_frequency_months integer, price_id uuid, base_price_cop numeric, extra_branch_price_cop numeric, country_id uuid, country_name text, calculated_price numeric, calculated_extra_branch_price numeric, calculated_promotional_price numeric, currency_code text, currency_symbol text)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    WITH
    branch_asset AS (
        -- FIXED: Filter by platform_id
        SELECT id FROM public.plan_assets WHERE asset_key = 'suc_glam' AND platform_id = p_platform_id LIMIT 1
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
        cr.csymbol AS currency_symbol
    FROM
        public.subscription_plans sp
    CROSS JOIN country_rates cr
    LEFT JOIN public.plan_country_configurations pcc ON sp.id = pcc.plan_id AND cr.cid = pcc.country_id
    LEFT JOIN current_tariffs ct ON sp.id = ct.subscription_plan_id
    WHERE
        sp.is_active = TRUE
        AND sp.platform_id = p_platform_id
        AND sp.is_default_trial = false
    ORDER BY
        sp.display_order, cr.cname;
END;
$$;

-- Step 2: Correct get_public_subscription_plans to be platform-aware
CREATE OR REPLACE FUNCTION public.get_public_subscription_plans(p_country_id uuid, p_platform_id uuid)
RETURNS TABLE(plan_id uuid, plan_name text, plan_description text, plan_features text[], billing_frequency_months integer, price_id uuid, calculated_price numeric, calculated_extra_branch_price numeric, calculated_promotional_price numeric, currency_code text, currency_symbol text, base_price numeric, active_branches_count integer, included_einvoices integer, extra_einvoice_price numeric, extra_branch_bonus_einvoices integer)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    WITH
    assets AS (
        -- FIXED: Filter by platform_id
        SELECT id, asset_key FROM public.plan_assets WHERE platform_id = p_platform_id AND asset_key IN ('suc_glam', 'fe_glam')
    ),
    plan_configs AS (
        SELECT pcc.plan_id, pcc.id as pcc_id, pcc.features
        FROM public.plan_country_configurations pcc
        WHERE pcc.country_id = p_country_id
    ),
    current_tariffs AS (
        SELECT DISTINCT ON (pt.subscription_plan_id)
            pt.id AS tariff_id,
            pt.subscription_plan_id,
            pt.base_price,
            pt.promotional_price,
            c.code AS base_currency_code,
            (SELECT pal.overage_unit_price FROM public.plan_asset_limits pal JOIN public.plan_country_configurations pcc ON pal.plan_country_config_id = pcc.id WHERE pcc.plan_id = pt.subscription_plan_id AND pcc.country_id = p_country_id AND pal.asset_id = (SELECT id FROM assets WHERE asset_key = 'suc_glam') LIMIT 1) AS extra_branch_price,
            (SELECT pal.value::INT FROM public.plan_asset_limits pal JOIN public.plan_country_configurations pcc ON pal.plan_country_config_id = pcc.id WHERE pcc.plan_id = pt.subscription_plan_id AND pcc.country_id = p_country_id AND pal.asset_id = (SELECT id FROM assets WHERE asset_key = 'fe_glam') LIMIT 1) AS included_einvoices,
            (SELECT pal.overage_unit_price FROM public.plan_asset_limits pal JOIN public.plan_country_configurations pcc ON pal.plan_country_config_id = pcc.id WHERE pcc.plan_id = pt.subscription_plan_id AND pcc.country_id = p_country_id AND pal.asset_id = (SELECT id FROM assets WHERE asset_key = 'fe_glam') LIMIT 1) AS extra_einvoice_price,
            (SELECT 0) AS extra_branch_bonus_einvoices
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
        WHERE c.is_active = TRUE AND c.id = p_country_id
    ),
    rates_from_usd AS (
        SELECT target_currency_code, rate FROM public.exchange_rates WHERE base_currency_code = 'USD'
    )
    SELECT
        sp.id AS plan_id,
        sp.name AS plan_name,
        sp.description AS plan_description,
        COALESCE(pc.features, ARRAY[]::text[]) AS plan_features,
        sp.billing_frequency_months,
        ct.tariff_id AS price_id,
        (CASE WHEN ct.base_currency_code = cr.ccode THEN ct.base_price ELSE floor( (ct.base_price::numeric / (SELECT rate FROM rates_from_usd WHERE target_currency_code = ct.base_currency_code LIMIT 1)) * cr.usd_to_target_rate::numeric ) + 0.99 END)::numeric AS calculated_price,
        (CASE WHEN ct.base_currency_code = cr.ccode THEN ct.extra_branch_price ELSE floor( (ct.extra_branch_price::numeric / (SELECT rate FROM rates_from_usd WHERE target_currency_code = ct.base_currency_code LIMIT 1)) * cr.usd_to_target_rate::numeric ) + 0.99 END)::numeric AS calculated_extra_branch_price,
        (CASE WHEN ct.base_currency_code = cr.ccode THEN COALESCE(ct.promotional_price, 0) ELSE floor( (COALESCE(ct.promotional_price, 0)::numeric / (SELECT rate FROM rates_from_usd WHERE target_currency_code = ct.base_currency_code LIMIT 1)) * cr.usd_to_target_rate::numeric ) + 0.99 END)::numeric AS calculated_promotional_price,
        cr.ccode AS currency_code,
        cr.csymbol AS currency_symbol,
        ct.base_price AS base_price,
        0 AS active_branches_count,
        ct.included_einvoices,
        (CASE WHEN ct.base_currency_code = cr.ccode THEN ct.extra_einvoice_price ELSE floor( (ct.extra_einvoice_price::numeric / (SELECT rate FROM rates_from_usd WHERE target_currency_code = ct.base_currency_code LIMIT 1)) * cr.usd_to_target_rate::numeric ) + 0.99 END)::numeric AS extra_einvoice_price,
        ct.extra_branch_bonus_einvoices
    FROM
        public.subscription_plans sp
    LEFT JOIN plan_configs pc ON sp.id = pc.plan_id
    CROSS JOIN country_rates cr
    LEFT JOIN current_tariffs ct ON sp.id = ct.subscription_plan_id
    WHERE
        sp.is_active = TRUE
        AND sp.platform_id = p_platform_id
        AND sp.is_default_trial = false
    ORDER BY
        sp.display_order, cr.cname;
END;
$$;

-- Step 3: Correct get_subscription_status_for_tenant to be platform-aware
DROP FUNCTION IF EXISTS public.get_subscription_status_for_tenant(uuid);
CREATE FUNCTION public.get_subscription_status_for_tenant(p_tenant_id uuid)
RETURNS TABLE(plan_name text, status text, is_trial boolean, trial_ends_at timestamp with time zone, starts_at timestamp with time zone, ends_at timestamp with time zone, max_users integer, max_branches integer, current_users integer, current_branches integer, plan_features text[])
LANGUAGE plpgsql
AS $$
DECLARE
    v_subscription record;
    v_pcc_id uuid;
    v_platform_id uuid;
BEGIN
    SELECT * INTO v_subscription
    FROM public.tenant_subscriptions
    WHERE tenant_id = p_tenant_id AND is_active = TRUE
    ORDER BY created_at DESC
    LIMIT 1;

    SELECT p.id INTO v_platform_id FROM public.tenants t JOIN public.platforms p ON t.platform_id = p.id WHERE t.id = p_tenant_id;

    SELECT pcc.id INTO v_pcc_id
    FROM public.plan_country_configurations pcc
    JOIN public.tenants t ON pcc.country_id = t.country_id
    WHERE t.id = p_tenant_id AND pcc.plan_id = v_subscription.active_plan_id;

    RETURN QUERY
    SELECT
        sp.name AS plan_name,
        v_subscription.status::text,
        v_subscription.is_trial,
        v_subscription.trial_ends_at,
        v_subscription.start_date AS starts_at,
        v_subscription.end_date AS ends_at,
        (SELECT pal.value FROM public.plan_asset_limits pal WHERE pal.plan_country_config_id = v_pcc_id AND pal.asset_id = (SELECT id FROM public.plan_assets WHERE asset_key = 'users_glam' AND platform_id = v_platform_id LIMIT 1))::integer AS max_users,
        (SELECT pal.value FROM public.plan_asset_limits pal WHERE pal.plan_country_config_id = v_pcc_id AND pal.asset_id = (SELECT id FROM public.plan_assets WHERE asset_key = 'suc_glam' AND platform_id = v_platform_id LIMIT 1))::integer AS max_branches,
        (SELECT COUNT(*) FROM public.user_assignments ua WHERE ua.tenant_id = p_tenant_id)::integer AS current_users,
        (SELECT COUNT(*) FROM public.branches b WHERE b.tenant_id = p_tenant_id)::integer AS current_branches,
        pcc.features AS plan_features
    FROM public.subscription_plans sp
    JOIN public.plan_country_configurations pcc ON pcc.id = v_pcc_id
    WHERE sp.id = v_subscription.active_plan_id;
END;
$$;

COMMIT;