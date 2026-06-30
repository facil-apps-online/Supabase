CREATE OR REPLACE FUNCTION "public"."get_public_subscription_plans"("p_country_id" "uuid", "p_platform_id" "uuid") RETURNS TABLE("plan_id" "uuid", "plan_name" "text", "plan_description" "text", "plan_features" "text"[], "billing_frequency_months" integer, "price_id" "uuid", "calculated_price" numeric, "calculated_extra_branch_price" numeric, "calculated_promotional_price" numeric, "currency_code" "text", "currency_symbol" "text", "base_price" numeric, "active_branches_count" integer, "included_einvoices" integer, "extra_einvoice_price" numeric, "extra_branch_bonus_einvoices" integer)
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY
    WITH
    assets AS (
        SELECT id, asset_key FROM public.plan_assets WHERE asset_key IN ('suc_glam', 'fe_glam')
    ),
    current_tariffs AS (
        SELECT DISTINCT ON (pt.subscription_plan_id)
            pt.id AS tariff_id,
            pt.subscription_plan_id,
            pt.base_price,
            pt.promotional_price,
            c.code AS base_currency_code,
            (SELECT pal.extra_unit_price FROM public.plan_asset_limits pal WHERE pal.plan_id = pt.subscription_plan_id AND pal.asset_id = (SELECT id FROM assets WHERE asset_key = 'suc_glam') LIMIT 1) AS extra_branch_price,
            (SELECT pal.value::INT FROM public.plan_asset_limits pal WHERE pal.plan_id = pt.subscription_plan_id AND pal.asset_id = (SELECT id FROM assets WHERE asset_key = 'fe_glam') AND pal.country_id = p_country_id LIMIT 1) AS included_einvoices,
            (SELECT pal.extra_unit_price FROM public.plan_asset_limits pal WHERE pal.plan_id = pt.subscription_plan_id AND pal.asset_id = (SELECT id FROM assets WHERE asset_key = 'fe_glam') AND pal.country_id = p_country_id LIMIT 1) AS extra_einvoice_price,
            (SELECT (pal.bonus_on_extra->>'quantity')::INT FROM public.plan_asset_limits pal WHERE pal.plan_id = pt.subscription_plan_id AND pal.asset_id = (SELECT id FROM assets WHERE asset_key = 'suc_glam') LIMIT 1) AS extra_branch_bonus_einvoices
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
        sp.features AS plan_features,
        sp.billing_frequency_months,
        ct.tariff_id AS price_id,
        (CASE
            WHEN ct.base_currency_code = cr.ccode THEN ct.base_price
            ELSE floor( (ct.base_price::numeric / (SELECT rate::numeric FROM rates_from_usd WHERE target_currency_code = ct.base_currency_code LIMIT 1)) * cr.usd_to_target_rate::numeric ) + 0.99
        END)::numeric AS calculated_price,
        (CASE
            WHEN ct.base_currency_code = cr.ccode THEN ct.extra_branch_price
            ELSE floor( (ct.extra_branch_price::numeric / (SELECT rate::numeric FROM rates_from_usd WHERE target_currency_code = ct.base_currency_code LIMIT 1)) * cr.usd_to_target_rate::numeric ) + 0.99
        END)::numeric AS calculated_extra_branch_price,
        (CASE
            WHEN ct.base_currency_code = cr.ccode THEN COALESCE(ct.promotional_price, 0)
            ELSE floor( (COALESCE(ct.promotional_price, 0)::numeric / (SELECT rate::numeric FROM rates_from_usd WHERE target_currency_code = ct.base_currency_code LIMIT 1)) * cr.usd_to_target_rate::numeric ) + 0.99
        END)::numeric AS calculated_promotional_price,
        cr.ccode AS currency_code,
        cr.csymbol AS currency_symbol,
        ct.base_price AS base_price,
        0 AS active_branches_count,
        ct.included_einvoices,
        (CASE
            WHEN ct.base_currency_code = cr.ccode THEN ct.extra_einvoice_price
            ELSE floor( (ct.extra_einvoice_price::numeric / (SELECT rate::numeric FROM rates_from_usd WHERE target_currency_code = ct.base_currency_code LIMIT 1)) * cr.usd_to_target_rate::numeric ) + 0.99
        END)::numeric AS extra_einvoice_price,
        ct.extra_branch_bonus_einvoices
    FROM
        public.subscription_plans sp
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