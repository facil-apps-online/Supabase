CREATE OR REPLACE FUNCTION public.get_public_subscription_plans(p_country_id uuid, p_platform_id uuid)
RETURNS TABLE(plan_id uuid, plan_name text, plan_description text, plan_features text[], billing_frequency_months integer, price_id uuid, calculated_price numeric, calculated_extra_branch_price numeric, calculated_promotional_price numeric, currency_code text, currency_symbol text, base_price numeric, active_branches_count integer, included_einvoices integer, extra_einvoice_price numeric, extra_branch_bonus_einvoices integer)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    WITH
    assets AS (
        SELECT pa.id, ap.purpose_key
        FROM public.plan_assets pa
        JOIN public.asset_purposes ap ON pa.asset_purpose_id = ap.id
        WHERE pa.platform_id = p_platform_id AND ap.purpose_key IN ('extra_branch', 'e_invoice')
    ),
    current_tariffs AS (
        SELECT DISTINCT ON (subscription_plan_id)
            id AS tariff_id,
            subscription_plan_id,
            base_price AS tariff_base_price,
            promotional_price AS tariff_promotional_price,
            (SELECT c.code FROM public.currencies c WHERE c.id = currency_id) AS base_currency_code
        FROM public.price_tariffs
        WHERE effective_date <= CURRENT_DATE
        ORDER BY subscription_plan_id, effective_date DESC
    ),
    -- NEW CTE for Colombian prices (for branch/storage)
    colombian_prices AS (
        SELECT
            pcc.plan_id,
            (SELECT pal.extra_unit_price FROM public.plan_asset_limits pal WHERE pal.plan_country_config_id = pcc.id AND pal.asset_id = (SELECT id FROM assets WHERE purpose_key = 'extra_branch')) AS extra_branch_price
        FROM public.plan_country_configurations pcc
        WHERE pcc.country_id = (SELECT id FROM public.countries WHERE iso_code = 'CO' LIMIT 1)
    ),
    -- Renamed from country_specific_assets to be clearer
    target_country_limits AS (
        SELECT
            pcc.plan_id,
            (SELECT pal.value::INT FROM public.plan_asset_limits pal WHERE pal.plan_country_config_id = pcc.id AND pal.asset_id = (SELECT id FROM assets WHERE purpose_key = 'e_invoice')) AS included_einvoices,
            (SELECT pal.extra_unit_price FROM public.plan_asset_limits pal WHERE pal.plan_country_config_id = pcc.id AND pal.asset_id = (SELECT id FROM assets WHERE purpose_key = 'e_invoice')) AS extra_einvoice_price
        FROM public.plan_country_configurations pcc
        WHERE pcc.country_id = p_country_id
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
    rates_to_usd AS (
        SELECT target_currency_code, rate FROM public.exchange_rates WHERE base_currency_code = 'USD'
    )
    SELECT
        sp.id AS plan_id,
        sp.name AS plan_name,
        sp.description AS plan_description,
        pcc.features AS plan_features,
        sp.billing_frequency_months,
        ct.tariff_id AS price_id,
        (CASE WHEN ct.base_currency_code = cr.ccode THEN ct.tariff_base_price ELSE floor( (ct.tariff_base_price::numeric / (SELECT rate FROM rates_to_usd WHERE target_currency_code = ct.base_currency_code LIMIT 1)) * cr.usd_to_target_rate::numeric ) + 0.99 END)::numeric AS calculated_price,
        (CASE WHEN ct.base_currency_code = cr.ccode THEN COALESCE(cp.extra_branch_price, 0) ELSE floor( (COALESCE(cp.extra_branch_price, 0)::numeric / (SELECT rate FROM rates_to_usd WHERE target_currency_code = ct.base_currency_code LIMIT 1)) * cr.usd_to_target_rate::numeric ) + 0.99 END)::numeric AS calculated_extra_branch_price,
        (CASE WHEN ct.base_currency_code = cr.ccode THEN COALESCE(ct.tariff_promotional_price, 0) ELSE floor( (COALESCE(ct.tariff_promotional_price, 0)::numeric / (SELECT rate FROM rates_to_usd WHERE target_currency_code = ct.base_currency_code LIMIT 1)) * cr.usd_to_target_rate::numeric ) + 0.99 END)::numeric AS calculated_promotional_price,
        cr.ccode AS currency_code,
        cr.csymbol AS currency_symbol,
        ct.tariff_base_price AS base_price,
        0 AS active_branches_count,
        tcl.included_einvoices,
        (CASE WHEN ct.base_currency_code = cr.ccode THEN tcl.extra_einvoice_price ELSE floor( (tcl.extra_einvoice_price::numeric / (SELECT rate FROM rates_to_usd WHERE target_currency_code = ct.base_currency_code LIMIT 1)) * cr.usd_to_target_rate::numeric ) + 0.99 END)::numeric AS extra_einvoice_price,
        0 AS extra_branch_bonus_einvoices
    FROM
        public.subscription_plans sp
    LEFT JOIN public.plan_country_configurations pcc ON sp.id = pcc.plan_id AND pcc.country_id = p_country_id
    LEFT JOIN current_tariffs ct ON sp.id = ct.subscription_plan_id
    LEFT JOIN colombian_prices cp ON sp.id = cp.plan_id
    LEFT JOIN target_country_limits tcl ON sp.id = tcl.plan_id
    CROSS JOIN country_rates cr
    WHERE
        sp.is_active = TRUE
        AND sp.platform_id = p_platform_id
        AND sp.is_default_trial = false
        AND pcc.is_active = TRUE
    ORDER BY
        sp.display_order, cr.cname;
END;
$$;