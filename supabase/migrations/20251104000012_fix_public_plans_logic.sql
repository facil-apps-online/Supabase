-- Migration to fix the logic of public subscription plan functions.
-- Version: 20251104000012

BEGIN;

-- Step 1: Correct the get_calculated_plan_prices function to prevent null features
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
        COALESCE(pcc.features, ARRAY[]::text[]) AS plan_features, -- FIXED: Prevent null array
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

-- Step 2: Correct the get_public_subscription_plans function to return all countries for the platform
CREATE OR REPLACE FUNCTION public.get_public_subscription_plans(p_country_id uuid, p_platform_id uuid)
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
    active_branches_count integer, 
    included_einvoices integer, 
    extra_einvoice_price numeric, 
    extra_branch_bonus_einvoices integer
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- This function now acts as a wrapper, ignoring p_country_id and returning all active countries for the platform.
    -- The frontend will be responsible for filtering by country.
    RETURN QUERY
    SELECT
        gcp.plan_id,
        gcp.plan_name,
        gcp.plan_description,
        gcp.plan_features,
        gcp.billing_frequency_months,
        gcp.price_id,
        gcp.calculated_price,
        gcp.calculated_extra_branch_price,
        gcp.calculated_promotional_price,
        gcp.currency_code,
        gcp.currency_symbol,
        gcp.base_price_cop, -- Renamed to match the output parameter
        0, -- active_branches_count is not relevant for public plans
        0, -- included_einvoices placeholder
        0, -- extra_einvoice_price placeholder
        0  -- extra_branch_bonus_einvoices placeholder
    FROM
        public.get_calculated_plan_prices(p_platform_id) gcp;
END;
$$;

COMMIT;
