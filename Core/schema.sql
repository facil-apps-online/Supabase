


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "pg_catalog";






COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "btree_gist" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "http" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "moddatetime" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgjwt" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE TYPE "public"."email_queue_status" AS ENUM (
    'PENDING',
    'PROCESSING',
    'SENT',
    'FAILED'
);


ALTER TYPE "public"."email_queue_status" OWNER TO "postgres";


CREATE TYPE "public"."subscription_asset_status" AS ENUM (
    'active',
    'cancelled'
);


ALTER TYPE "public"."subscription_asset_status" OWNER TO "postgres";


CREATE TYPE "public"."subscription_asset_type" AS ENUM (
    'branch',
    'user'
);


ALTER TYPE "public"."subscription_asset_type" OWNER TO "postgres";


CREATE TYPE "public"."tenant_subscription_status" AS ENUM (
    'trial',
    'active',
    'inactive',
    'cancelled',
    'grace_period'
);


ALTER TYPE "public"."tenant_subscription_status" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."check_superadmin_exists"() RETURNS boolean
    LANGUAGE "sql" SECURITY DEFINER
    AS $$
  SELECT EXISTS (
    SELECT 1
    FROM auth.users,
         jsonb_array_elements(raw_app_meta_data->'assignments') as assignment
    WHERE assignment->>'role' = 'super_admin'
  );
$$;


ALTER FUNCTION "public"."check_superadmin_exists"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."clone_configurations_from_platform"("p_source_platform_id" "uuid", "p_target_platform_id" "uuid", "p_config_to_clone" "text"[]) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    -- Cursors and record variables
    source_plan record;
    new_plan_id uuid;
    source_tariff record;
BEGIN
    -- Check if 'PLANS' is in the array of things to clone
    IF 'PLANS' = ANY(p_config_to_clone) THEN

        -- 1. Delete existing plans for the target platform
        RAISE NOTICE 'Deleting existing plans for target platform %', p_target_platform_id;
        DELETE FROM public.subscription_plans WHERE platform_id = p_target_platform_id;

        -- 2. Loop through source plans and clone them
        FOR source_plan IN
            SELECT * FROM public.subscription_plans WHERE platform_id = p_source_platform_id
        LOOP
            RAISE NOTICE 'Cloning plan %', source_plan.name;

            -- 3. Insert new plan for the target platform, getting the new ID
            INSERT INTO public.subscription_plans (
                name, description, duration_days, is_active, 
                billing_frequency_months, display_order, grace_period_days, 
                platform_id, is_default_trial
            )
            VALUES (
                source_plan.name, source_plan.description, source_plan.duration_days, source_plan.is_active,
                source_plan.billing_frequency_months, source_plan.display_order, source_plan.grace_period_days,
                p_target_platform_id, source_plan.is_default_trial
            )
            RETURNING id INTO new_plan_id;

            -- 4. Loop through tariffs of the source plan and clone them
            FOR source_tariff IN
                SELECT * FROM public.price_tariffs WHERE subscription_plan_id = source_plan.id
            LOOP
                RAISE NOTICE '  Cloning tariff effective %', source_tariff.effective_date;

                INSERT INTO public.price_tariffs (
                    subscription_plan_id, effective_date, base_price, 
                    currency_id, promotional_price
                )
                VALUES (
                    new_plan_id, source_tariff.effective_date, source_tariff.base_price,
                    source_tariff.currency_id, source_tariff.promotional_price
                );
            END LOOP;
            
        END LOOP;
    END IF;

    -- Logic for cloning other configs ('ASSETS', etc.) will go here later.

END;
$$;


ALTER FUNCTION "public"."clone_configurations_from_platform"("p_source_platform_id" "uuid", "p_target_platform_id" "uuid", "p_config_to_clone" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_calculated_plan_prices"("p_platform_id" "uuid") RETURNS TABLE("plan_id" "uuid", "plan_name" "text", "plan_description" "text", "plan_features" "text"[], "billing_frequency_months" integer, "price_id" "uuid", "base_price_cop" numeric, "extra_branch_price_cop" numeric, "country_id" "uuid", "country_name" "text", "calculated_price" numeric, "calculated_extra_branch_price" numeric, "calculated_promotional_price" numeric, "currency_code" "text", "currency_symbol" "text")
    LANGUAGE "plpgsql"
    AS $$
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


ALTER FUNCTION "public"."get_calculated_plan_prices"("p_platform_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_current_role_name"() RETURNS "text"
    LANGUAGE "sql" STABLE
    AS $$
  SELECT NULLIF(current_setting('app.current_assignment.role_name', TRUE), '');
$$;


ALTER FUNCTION "public"."get_current_role_name"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_current_tenant_id"() RETURNS "uuid"
    LANGUAGE "plpgsql" STABLE
    AS $$
DECLARE
    tenant_id uuid;
BEGIN
    SELECT NULLIF(current_setting('request.jwt.claims', true)::jsonb -> 'app_metadata' -> 'assignments' -> 0 ->> 'tenant_id', '')::uuid INTO tenant_id;
    RETURN tenant_id;
END;
$$;


ALTER FUNCTION "public"."get_current_tenant_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_platform_financial_stats"("p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("mrr" numeric, "arr" numeric, "total_revenue_last_30_days" numeric, "new_tenants_last_30_days" bigint, "active_subscriptions" bigint, "payments_last_30_days" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    RETURN QUERY
    WITH valid_payments AS (
        -- Filtra los pagos completados y de producción, uniéndolos con tenants y plataformas.
        SELECT 
            (pi.amount_in_cents / 100.0) as amount, -- Corregido
            pi.created_at,
            t.id as tenant_id,
            t.created_at as tenant_created_at,
            t.platform_id
        FROM public.payment_intents pi
        JOIN public.tenants t ON pi.tenant_id = t.id
        WHERE pi.status = 'COMPLETED'
          AND pi.environment <> 'test' -- Confirmado
          AND (p_platform_id IS NULL OR t.platform_id = p_platform_id)
    ),
    monthly_revenue AS (
        -- Calcula los ingresos del último mes completo para el MRR.
        SELECT COALESCE(SUM(amount), 0) as total
        FROM valid_payments
        WHERE created_at >= date_trunc('month', NOW() - interval '1 month')
          AND created_at < date_trunc('month', NOW())
    )
    SELECT
        -- MRR: Ingresos del último mes completo.
        (SELECT total FROM monthly_revenue) AS mrr,
        
        -- ARR: MRR multiplicado por 12.
        (SELECT total * 12 FROM monthly_revenue) AS arr,
        
        -- Ingresos totales de los últimos 30 días.
        (SELECT COALESCE(SUM(amount), 0) FROM valid_payments WHERE created_at >= NOW() - interval '30 days') AS total_revenue_last_30_days,
        
        -- Nuevos tenants en los últimos 30 días para la plataforma seleccionada.
        (SELECT COUNT(DISTINCT tenant_id) FROM valid_payments WHERE tenant_created_at >= NOW() - interval '30 days') AS new_tenants_last_30_days,

        -- Suscripciones activas para la plataforma.
        (SELECT COUNT(*) FROM public.tenant_subscriptions ts JOIN public.tenants t ON ts.tenant_id = t.id WHERE ts.is_active = TRUE AND (p_platform_id IS NULL OR t.platform_id = p_platform_id)) AS active_subscriptions,

        -- Conteo de pagos en los últimos 30 días.
        (SELECT COUNT(*) FROM valid_payments WHERE created_at >= NOW() - interval '30 days') AS payments_last_30_days;
END;
$$;


ALTER FUNCTION "public"."get_platform_financial_stats"("p_platform_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_platform_level_assignments"() RETURNS TABLE("id" "uuid", "full_name" "text", "first_name" "text", "last_name" "text", "email" "text", "platform_roles" "jsonb")
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  RETURN QUERY
  SELECT
    u.id,
    (u.raw_user_meta_data->>'first_name') || ' ' || (u.raw_user_meta_data->>'last_name') AS full_name,
    u.raw_user_meta_data->>'first_name' AS first_name,
    u.raw_user_meta_data->>'last_name' AS last_name,
    u.email::text,
    jsonb_build_object(
      'app_super_admin', (
        SELECT COALESCE(jsonb_agg(jsonb_build_object('platform_id', pa.platform_id, 'platform_name', p.name)), '[]'::jsonb)
        FROM public.platform_assignments pa
        JOIN public.roles r ON pa.role_id = r.id
        JOIN public.platforms p ON pa.platform_id = p.id
        WHERE r.name = 'app_super_admin' AND pa.user_id = u.id
      ),
      'investor', (
        SELECT COALESCE(jsonb_agg(jsonb_build_object('platform_id', ips.platform_id, 'platform_name', p.name, 'stake_percentage', ips.investment_share * 100)), '[]'::jsonb)
        FROM public.investor_platform_shares ips
        JOIN public.platforms p ON ips.platform_id = p.id
        WHERE ips.user_id = u.id
      ),
      'vendor', (
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'id', vpc.id,
            'platform_id', vpc.platform_id, 
            'platform_name', p.name,
            'first_payment_commission_rate', vpc.first_payment_commission_rate,
            'recurring_payment_commission_rate', vpc.recurring_payment_commission_rate
        )), '[]'::jsonb)
        FROM public.vendor_platform_commissions vpc
        JOIN public.platforms p ON vpc.platform_id = p.id
        WHERE vpc.user_id = u.id
      )
    ) AS platform_roles
  FROM auth.users u
  WHERE u.email !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}_';
END;
$$;


ALTER FUNCTION "public"."get_platform_level_assignments"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_platforms_stats"() RETURNS TABLE("platform_id" "uuid", "platform_name" "text", "mrr" numeric, "active_subscriptions" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    RETURN QUERY
    WITH monthly_revenue AS (
        SELECT
            t.platform_id,
            SUM(p.amount_in_cents / 100.0) as total
        FROM public.payments p
        JOIN public.tenants t ON p.tenant_id = t.id
        WHERE p.status = 'APPROVED'
          AND p.environment = 'production'
          AND p.created_at >= date_trunc('month', NOW() - interval '1 month')
          AND p.created_at < date_trunc('month', NOW())
        GROUP BY t.platform_id
    ),
    active_subs AS (
        SELECT
            t.platform_id,
            COUNT(*) as total
        FROM public.tenant_subscriptions ts
        JOIN public.tenants t ON ts.tenant_id = t.id
        WHERE ts.is_active = TRUE
        GROUP BY t.platform_id
    )
    SELECT
        p.id as platform_id,
        p.name as platform_name,
        COALESCE(mr.total, 0) as mrr,
        COALESCE(asub.total, 0) as active_subscriptions
    FROM public.platforms p
    LEFT JOIN monthly_revenue mr ON p.id = mr.platform_id
    LEFT JOIN active_subs asub ON p.id = asub.platform_id;
END;
$$;


ALTER FUNCTION "public"."get_platforms_stats"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_public_subscription_plans"("p_country_id" "uuid", "p_platform_id" "uuid") RETURNS TABLE("plan_id" "uuid", "plan_name" "text", "plan_description" "text", "plan_features" "text"[], "billing_frequency_months" integer, "price_id" "uuid", "calculated_price" numeric, "calculated_extra_branch_price" numeric, "calculated_promotional_price" numeric, "currency_code" "text", "currency_symbol" "text", "original_base_price" numeric, "active_branches_count" integer, "included_einvoices" integer, "extra_einvoice_price" numeric, "extra_branch_bonus_einvoices" integer)
    LANGUAGE "plpgsql"
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
    colombian_prices AS (
        SELECT
            pcc.plan_id,
            (SELECT pal.extra_unit_price FROM public.plan_asset_limits pal WHERE pal.plan_country_config_id = pcc.id AND pal.asset_id = (SELECT id FROM assets WHERE purpose_key = 'extra_branch')) AS extra_branch_price
        FROM public.plan_country_configurations pcc
        WHERE pcc.country_id = (SELECT id FROM public.countries WHERE iso_code = 'CO' LIMIT 1)
    ),
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
        ct.tariff_base_price AS original_base_price,
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


ALTER FUNCTION "public"."get_public_subscription_plans"("p_country_id" "uuid", "p_platform_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_subscription_plans_for_tenant"("p_tenant_id" "uuid", "p_platform_id" "uuid") RETURNS TABLE("plan_id" "uuid", "plan_name" "text", "plan_description" "text", "plan_features" "text"[], "billing_frequency_months" integer, "price_id" "uuid", "calculated_price" numeric, "calculated_extra_branch_price" numeric, "calculated_promotional_price" numeric, "currency_code" "text", "currency_symbol" "text", "base_price" numeric, "active_branches_count" integer)
    LANGUAGE "plpgsql"
    AS $$
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
$$;


ALTER FUNCTION "public"."get_subscription_plans_for_tenant"("p_tenant_id" "uuid", "p_platform_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_superadmin_payment_stats"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    investor_payouts jsonb;
    vendor_commissions jsonb;
BEGIN
    WITH approved_payments AS (
        SELECT
            p.amount_in_cents / 100.0 as amount,
            t.platform_id,
            p.tenant_id,
            p.created_at
        FROM public.payments p
        JOIN public.tenants t ON p.tenant_id = t.id
        WHERE p.status = 'APPROVED' AND p.environment = 'production'
    )
    SELECT jsonb_agg(t)
    INTO investor_payouts
    FROM (
        SELECT
            ap.platform_id,
            p.name as platform_name,
            ips.user_id as investor_id,
            u.email as investor_email,
            SUM(ap.amount * ips.investment_share) as total_payout
        FROM approved_payments ap
        JOIN public.investor_platform_shares ips ON ap.platform_id = ips.platform_id
        JOIN public.platforms p ON ap.platform_id = p.id
        JOIN auth.users u ON ips.user_id = u.id
        GROUP BY ap.platform_id, p.name, ips.user_id, u.email
    ) t;

    WITH approved_payments AS (
        SELECT
            p.amount_in_cents / 100.0 as amount,
            t.platform_id,
            p.tenant_id,
            p.created_at
        FROM public.payments p
        JOIN public.tenants t ON p.tenant_id = t.id
        WHERE p.status = 'APPROVED' AND p.environment = 'production'
    ),
    ranked_payments AS (
        SELECT
            *,
            ROW_NUMBER() OVER(PARTITION BY tenant_id ORDER BY created_at) as rn
        FROM approved_payments
    )
    SELECT jsonb_agg(t)
    INTO vendor_commissions
    FROM (
        SELECT
            rp.platform_id,
            p.name as platform_name,
            vpc.user_id as vendor_id,
            u.email as vendor_email,
            SUM(
                CASE
                    WHEN rp.rn = 1 THEN rp.amount * vpc.first_payment_commission_rate
                    ELSE rp.amount * vpc.recurring_payment_commission_rate
                END
            ) as total_commission
        FROM ranked_payments rp
        JOIN public.vendor_platform_commissions vpc ON rp.platform_id = vpc.platform_id
        JOIN public.platforms p ON rp.platform_id = p.id
        JOIN auth.users u ON vpc.user_id = u.id
        GROUP BY rp.platform_id, p.name, vpc.user_id, u.email
    ) t;

    RETURN jsonb_build_object(
        'investor_payouts', COALESCE(investor_payouts, '[]'::jsonb),
        'vendor_commissions', COALESCE(vendor_commissions, '[]'::jsonb)
    );
END;
$$;


ALTER FUNCTION "public"."get_superadmin_payment_stats"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_tenant_for_microsite"("p_country_iso_code" "text", "p_slug" "text", "p_platform_id" "uuid") RETURNS json
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_tenant_record RECORD;
BEGIN
    -- 1. Find the tenant based on platform, country ISO code, and slug
    SELECT 
        t.id,
        t.name,
        t.logo_url,
        t.slug,
        t.description,
        t.country_id,
        t.platform_id
    INTO v_tenant_record
    FROM public.tenants t
    JOIN public.countries c ON t.country_id = c.id
    WHERE lower(c.iso_code) = lower(p_country_iso_code)
      AND lower(t.slug) = lower(p_slug)
      AND t.platform_id = p_platform_id;

    IF v_tenant_record.id IS NULL THEN
        RETURN null;
    END IF;

    -- 2. Return tenant data as JSON. Social networks will be fetched separately.
    RETURN json_build_object(
        'id', v_tenant_record.id,
        'name', v_tenant_record.name,
        'logo_url', v_tenant_record.logo_url,
        'slug', v_tenant_record.slug,
        'description', v_tenant_record.description,
        'country_id', v_tenant_record.country_id,
        'platform_id', v_tenant_record.platform_id
    );
END;
$$;


ALTER FUNCTION "public"."get_tenant_for_microsite"("p_country_iso_code" "text", "p_slug" "text", "p_platform_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."invoke_core_orphan_cleanup"() RETURNS json
    LANGUAGE "plpgsql"
    AS $$
declare
  project_ref text;
  anon_key text;
  function_url text;
  response json;
begin
  -- Securely get secrets from the Vault
  select decrypted_secret into project_ref from vault.decrypted_secrets where name = 'project_ref';
  select decrypted_secret into anon_key from vault.decrypted_secrets where name = 'anon_key';

  if project_ref is null or anon_key is null then
    raise exception 'project_ref or anon_key not found in vault.decrypted_secrets';
  end if;

  -- Construct the function URL
  function_url := 'https://' || project_ref || '.supabase.co/functions/v1/core-orphan-cleanup';

  -- Perform the HTTP POST request
  select
      net.http_post(
          url := function_url,
          headers := jsonb_build_object(
              'Content-Type', 'application/json',
              'Authorization', 'Bearer ' || anon_key
          )
      )
  into response;

  return response;
end;
$$;


ALTER FUNCTION "public"."invoke_core_orphan_cleanup"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_super_admin"() RETURNS boolean
    LANGUAGE "sql" STABLE
    AS $$
  SELECT get_current_role_name() = 'super_admin';
$$;


ALTER FUNCTION "public"."is_super_admin"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."asset_purposes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "purpose_key" "text" NOT NULL,
    "description" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."asset_purposes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."asset_usage_tracking" (
    "id" bigint NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "asset_id" "uuid" NOT NULL,
    "usage_period_start" "date" NOT NULL,
    "usage_period_end" "date" NOT NULL,
    "quantity_used" bigint DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "platform_id" "uuid" NOT NULL
);


ALTER TABLE "public"."asset_usage_tracking" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."asset_usage_tracking_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."asset_usage_tracking_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."asset_usage_tracking_id_seq" OWNED BY "public"."asset_usage_tracking"."id";



CREATE TABLE IF NOT EXISTS "public"."billing_entities" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "legal_name" "text" NOT NULL,
    "tax_id" "text",
    "billing_address_line1" "text",
    "billing_address_line2" "text",
    "billing_city" "text",
    "billing_state" "text",
    "billing_postal_code" "text",
    "billing_country_id" "uuid",
    "contact_email" "text",
    "contact_phone" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."billing_entities" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."countries" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "iso_code" "text" NOT NULL,
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "default_language_iso_code" "text",
    "uses_auto_pricing" boolean DEFAULT false NOT NULL,
    "default_currency_id" "uuid",
    "default_localization_id" "uuid",
    "phone_prefix_id" "uuid",
    "default_latitude" double precision,
    "default_longitude" double precision,
    "timezones" "jsonb",
    "field_placeholders" "jsonb"
);


ALTER TABLE "public"."countries" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."country_timezones" (
    "country_id" "uuid" NOT NULL,
    "timezone_id" "uuid" NOT NULL
);


ALTER TABLE "public"."country_timezones" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."currencies" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "code" "text" NOT NULL,
    "symbol" "text" NOT NULL,
    "format" "text",
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "symbol_position" character varying(10) DEFAULT 'before'::character varying NOT NULL,
    "decimal_separator" character(1) DEFAULT '.'::"bpchar" NOT NULL,
    "thousands_separator" character(1) DEFAULT ','::"bpchar" NOT NULL,
    "decimal_places" integer DEFAULT 2 NOT NULL
);


ALTER TABLE "public"."currencies" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."email_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "recipient_email" "text" NOT NULL,
    "template_id" "uuid",
    "status" "text" NOT NULL,
    "error_message" "text",
    "sent_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "platform_id" "uuid" NOT NULL
);


ALTER TABLE "public"."email_logs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."email_queue" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "recipient_user_id" "uuid" NOT NULL,
    "template_type" "text" NOT NULL,
    "template_data" "jsonb" NOT NULL,
    "status" "public"."email_queue_status" DEFAULT 'PENDING'::"public"."email_queue_status" NOT NULL,
    "attempts" integer DEFAULT 0 NOT NULL,
    "last_attempt_at" timestamp with time zone,
    "error_message" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."email_queue" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."email_templates" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "template_type" "text" NOT NULL,
    "name" "text" NOT NULL,
    "subject" "text" NOT NULL,
    "body_html" "text" NOT NULL,
    "language_id" "uuid" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "propagate_to_new_tenants" boolean DEFAULT false NOT NULL,
    "platform_id" "uuid",
    "is_customizable" boolean DEFAULT true NOT NULL,
    "is_disableable" boolean DEFAULT true NOT NULL
);


ALTER TABLE "public"."email_templates" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."error_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid",
    "user_id" "uuid",
    "error_message" "text" NOT NULL,
    "stack_trace" "text",
    "error_code" "text",
    "severity" "text" DEFAULT 'error'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "platform_id" "uuid",
    CONSTRAINT "error_logs_severity_check" CHECK (("severity" = ANY (ARRAY['info'::"text", 'warning'::"text", 'error'::"text", 'critical'::"text"])))
);


ALTER TABLE "public"."error_logs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."exchange_rates" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "base_currency_code" "text" NOT NULL,
    "target_currency_code" "text" NOT NULL,
    "rate" numeric(12,6) NOT NULL,
    "last_updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."exchange_rates" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."generic_taxes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "rate" numeric(5,2) NOT NULL,
    "country_id" "uuid" NOT NULL,
    "description" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."generic_taxes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."global_settings" (
    "id" integer NOT NULL,
    "base_currency_id" "uuid",
    "default_tax_rate" numeric(5,2) DEFAULT 0.00,
    "default_tax_name" "text" DEFAULT 'IVA'::"text",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "company_name" "text",
    "contact_email" "text",
    "address" "text",
    "trial_duration_days" integer DEFAULT 14 NOT NULL,
    "trial_grace_period_days" integer DEFAULT 3 NOT NULL,
    CONSTRAINT "global_settings_id_check" CHECK (("id" = 1))
);


ALTER TABLE "public"."global_settings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."integration_auth_methods" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "method" "text" NOT NULL,
    "description" "text",
    "config_schema" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."integration_auth_methods" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."integration_body_formats" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "format" "text" NOT NULL,
    "description" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."integration_body_formats" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."integration_categories" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "slug" "text" NOT NULL,
    "description" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."integration_categories" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."integration_http_methods" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "method" "text" NOT NULL,
    "description" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."integration_http_methods" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."integration_providers" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "logo_url" "text",
    "country_id" "uuid" NOT NULL,
    "category_id" "uuid" NOT NULL,
    "status" "text" NOT NULL,
    "endpoints" "jsonb" NOT NULL,
    "config_schema" "jsonb" NOT NULL,
    "api_schema" "jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "slug" "text" NOT NULL,
    "http_method_id" "uuid",
    "body_format_id" "uuid",
    "auth_method_id" "uuid",
    "http_headers" "jsonb",
    "authentication_config" "jsonb",
    "body_template" "text",
    "response_mapping" "jsonb"
);


ALTER TABLE "public"."integration_providers" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."integration_record" (
    "id" "uuid",
    "tenant_id" "uuid",
    "provider" "text",
    "access_token" "text",
    "encrypted_refresh_token" "bytea",
    "encryption_nonce" "bytea",
    "account_email" "text",
    "created_at" timestamp with time zone,
    "updated_at" timestamp with time zone,
    "platform_id" "uuid"
);


ALTER TABLE "public"."integration_record" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."integrations_config" (
    "key" "text" NOT NULL,
    "value" "text" NOT NULL
);


ALTER TABLE "public"."integrations_config" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."investor_platform_shares" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "platform_id" "uuid" NOT NULL,
    "investment_share" numeric(5,4) NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "investor_platform_shares_investment_share_check" CHECK ((("investment_share" > (0)::numeric) AND ("investment_share" <= (1)::numeric)))
);


ALTER TABLE "public"."investor_platform_shares" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."investor_platform_stakes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "investor_user_id" "uuid" NOT NULL,
    "platform_id" "uuid" NOT NULL,
    "stake_percentage" numeric(5,2) NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "investor_platform_stakes_stake_percentage_check" CHECK ((("stake_percentage" > (0)::numeric) AND ("stake_percentage" <= (100)::numeric)))
);


ALTER TABLE "public"."investor_platform_stakes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."languages" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "iso_code" character varying(10) NOT NULL,
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."languages" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."monthly_charges" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "billing_period_start" "date" NOT NULL,
    "billing_period_end" "date" NOT NULL,
    "base_plan_charge" numeric(10,2) DEFAULT 0.00 NOT NULL,
    "total_overage_charge" numeric(10,2) DEFAULT 0.00 NOT NULL,
    "total_charge" numeric(10,2) DEFAULT 0.00 NOT NULL,
    "currency_code" "text" NOT NULL,
    "currency_symbol" "text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "platform_id" "uuid" NOT NULL
);


ALTER TABLE "public"."monthly_charges" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."payment_intents" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "status" "text" DEFAULT 'PENDING'::"text" NOT NULL,
    "amount_in_cents" bigint NOT NULL,
    "currency" character varying(3) NOT NULL,
    "reference" "text" NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "environment" "text" NOT NULL,
    "actions_on_success" "jsonb",
    "platform_id" "uuid" NOT NULL,
    CONSTRAINT "payment_intents_environment_check" CHECK (("environment" = ANY (ARRAY['test'::"text", 'production'::"text"])))
);


ALTER TABLE "public"."payment_intents" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."payments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "provider" "text" NOT NULL,
    "provider_payment_id" "text" NOT NULL,
    "amount_in_cents" bigint NOT NULL,
    "currency" character varying(3) NOT NULL,
    "status" "text" NOT NULL,
    "reference" "text" NOT NULL,
    "environment" "text" NOT NULL,
    "full_response" "jsonb",
    "payment_date" timestamp with time zone NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "platform_id" "uuid" NOT NULL
);


ALTER TABLE "public"."payments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."phone_prefixes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "country_name" "text" NOT NULL,
    "iso_code" character varying(2) NOT NULL,
    "prefix" character varying(10) NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."phone_prefixes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."plan_asset_bonuses" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "source_asset_limit_id" "uuid" NOT NULL,
    "bonus_asset_id" "uuid" NOT NULL,
    "quantity" integer NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "quantity_must_be_positive" CHECK (("quantity" > 0))
);


ALTER TABLE "public"."plan_asset_bonuses" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."plan_asset_limits" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "plan_country_config_id" "uuid" NOT NULL,
    "asset_id" "uuid" NOT NULL,
    "value" "text" NOT NULL,
    "extra_unit_price" numeric(10,4) DEFAULT 0 NOT NULL,
    "overage_unit_price" numeric(10,4) DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."plan_asset_limits" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."plan_assets" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "platform_id" "uuid" NOT NULL,
    "asset_key" "text" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "data_type" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "asset_purpose_id" "uuid" NOT NULL,
    CONSTRAINT "plan_assets_data_type_check" CHECK (("data_type" = ANY (ARRAY['boolean'::"text", 'numeric'::"text"])))
);


ALTER TABLE "public"."plan_assets" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."plan_country_configurations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "plan_id" "uuid" NOT NULL,
    "country_id" "uuid" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "features" "text"[] DEFAULT ARRAY[]::"text"[],
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."plan_country_configurations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."platform_assignments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "platform_id" "uuid" NOT NULL,
    "role_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."platform_assignments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."platform_countries" (
    "platform_id" "uuid" NOT NULL,
    "country_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."platform_countries" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."platforms" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "base_url" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "default_currency_id" "uuid",
    "default_language_id" "uuid"
);


ALTER TABLE "public"."platforms" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."price_tariffs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "subscription_plan_id" "uuid" NOT NULL,
    "effective_date" timestamp with time zone NOT NULL,
    "base_price" numeric(10,2) DEFAULT 0 NOT NULL,
    "currency_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "promotional_price" numeric(10,2)
);


ALTER TABLE "public"."price_tariffs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."roles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "description" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "tenant_id" "uuid",
    "platform_id" "uuid"
);


ALTER TABLE "public"."roles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."subscription_assets" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_subscription_id" "uuid" NOT NULL,
    "asset_type" "public"."subscription_asset_type" NOT NULL,
    "asset_reference_id" "uuid" NOT NULL,
    "status" "public"."subscription_asset_status" DEFAULT 'active'::"public"."subscription_asset_status" NOT NULL,
    "added_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "cancelled_at" timestamp with time zone,
    "price_at_addition" numeric(10,2) NOT NULL,
    "platform_id" "uuid" NOT NULL
);


ALTER TABLE "public"."subscription_assets" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."subscription_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "subscription_id" "uuid" NOT NULL,
    "item_type" "text" NOT NULL,
    "item_id" "uuid",
    "quantity" integer DEFAULT 1 NOT NULL,
    "unit_price_at_addition" numeric(10,2) NOT NULL,
    "added_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "platform_id" "uuid" NOT NULL,
    CONSTRAINT "check_item_type" CHECK (("item_type" = ANY (ARRAY['extra_branch'::"text", 'extra_user'::"text", 'advanced_reports'::"text"])))
);


ALTER TABLE "public"."subscription_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."subscription_plans" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "duration_days" integer DEFAULT 30 NOT NULL,
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "billing_frequency_months" integer DEFAULT 1 NOT NULL,
    "display_order" integer DEFAULT 0 NOT NULL,
    "grace_period_days" integer DEFAULT 7 NOT NULL,
    "platform_id" "uuid" NOT NULL,
    "is_default_trial" boolean DEFAULT false NOT NULL
);


ALTER TABLE "public"."subscription_plans" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."system_alerts" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "type" "text" NOT NULL,
    "message" "text" NOT NULL,
    "details" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "is_resolved" boolean DEFAULT false,
    "resolved_at" timestamp with time zone,
    "resolved_by" "uuid",
    "platform_id" "uuid" NOT NULL
);


ALTER TABLE "public"."system_alerts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tariff_asset_prices" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tariff_id" "uuid" NOT NULL,
    "asset_id" "uuid" NOT NULL,
    "extra_unit_price" numeric(10,2) DEFAULT 0 NOT NULL,
    "overage_unit_price" numeric(10,4) DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."tariff_asset_prices" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tenant_integrations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "provider" "text" NOT NULL,
    "access_token" "text",
    "account_email" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "expires_at" timestamp with time zone,
    "encrypted_credentials" "text",
    "nonce" "text",
    "environment" "text" DEFAULT 'production'::"text" NOT NULL,
    "is_active" boolean DEFAULT false NOT NULL,
    "platform_id" "uuid" NOT NULL
);


ALTER TABLE "public"."tenant_integrations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tenant_settings" (
    "tenant_id" "uuid" NOT NULL,
    "settings_data" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "platform_id" "uuid" NOT NULL
);


ALTER TABLE "public"."tenant_settings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tenant_subscriptions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "plan_country_configuration_id" "uuid",
    "start_date" timestamp with time zone DEFAULT "now"() NOT NULL,
    "end_date" timestamp with time zone,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "is_trial" boolean DEFAULT false NOT NULL,
    "platform_id" "uuid" NOT NULL
);


ALTER TABLE "public"."tenant_subscriptions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tenant_template_settings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "template_type" "text" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "template_id" "uuid",
    "platform_id" "uuid" NOT NULL
);


ALTER TABLE "public"."tenant_template_settings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tenants" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "subscription_status" "text" DEFAULT 'trial'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "default_language_code" "text",
    "default_currency_id" "uuid",
    "default_timezone" "text",
    "contact_person" "text",
    "contact_email" "text",
    "contact_phone" "text",
    "country_id" "uuid",
    "is_active" boolean DEFAULT true,
    "logo_url" "text",
    "notes" "text",
    "legal_name" "text",
    "tax_id" "text",
    "billing_address" "text",
    "website" "text",
    "whatsapp_phone" "text",
    "einvoicing_email" "text",
    "physical_address_line1" "text",
    "physical_address_line2" "text",
    "physical_city" "text",
    "physical_state" "text",
    "physical_postal_code" "text",
    "latitude" numeric(10,7),
    "longitude" numeric(10,7),
    "commercial_email" "text",
    "integrations_mode" "text" DEFAULT 'production'::"text" NOT NULL,
    "is_system_owner" boolean DEFAULT false NOT NULL,
    "platform_id" "uuid" NOT NULL,
    "primary_color" "text",
    "secondary_color" "text",
    "slug" "text",
    "description" "text",
    CONSTRAINT "tenants_subscription_status_check" CHECK (("subscription_status" = ANY (ARRAY['trial'::"text", 'active'::"text", 'inactive'::"text", 'expired'::"text", 'canceled'::"text", 'grace_period'::"text"]))),
    CONSTRAINT "valid_slug_format" CHECK ((("slug" IS NULL) OR (("slug" ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'::"text") AND ("length"("slug") > 2))))
);


ALTER TABLE "public"."tenants" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."timezones" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "offset_str" "text" NOT NULL,
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "original_countries" "text"[]
);


ALTER TABLE "public"."timezones" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."translations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "language_id" "uuid" NOT NULL,
    "key" "text" NOT NULL,
    "value" "text" NOT NULL,
    "context" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "platform_id" "uuid"
);


ALTER TABLE "public"."translations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."vendor_platform_commissions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "platform_id" "uuid" NOT NULL,
    "first_payment_commission_rate" numeric(5,4) DEFAULT 0.50 NOT NULL,
    "recurring_payment_commission_rate" numeric(5,4) DEFAULT 0.10 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."vendor_platform_commissions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."vendor_tenants" (
    "user_id" "uuid" NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "platform_id" "uuid" NOT NULL
);


ALTER TABLE "public"."vendor_tenants" OWNER TO "postgres";


ALTER TABLE ONLY "public"."asset_usage_tracking" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."asset_usage_tracking_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."asset_purposes"
    ADD CONSTRAINT "asset_purposes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."asset_purposes"
    ADD CONSTRAINT "asset_purposes_purpose_key_unique" UNIQUE ("purpose_key");



ALTER TABLE ONLY "public"."asset_usage_tracking"
    ADD CONSTRAINT "asset_usage_tracking_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."asset_usage_tracking"
    ADD CONSTRAINT "asset_usage_tracking_tenant_asset_period_unique" UNIQUE ("tenant_id", "asset_id", "usage_period_start");



ALTER TABLE ONLY "public"."billing_entities"
    ADD CONSTRAINT "billing_entities_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."countries"
    ADD CONSTRAINT "countries_iso_code_key" UNIQUE ("iso_code");



ALTER TABLE ONLY "public"."countries"
    ADD CONSTRAINT "countries_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."countries"
    ADD CONSTRAINT "countries_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."country_timezones"
    ADD CONSTRAINT "country_timezones_pkey" PRIMARY KEY ("country_id", "timezone_id");



ALTER TABLE ONLY "public"."currencies"
    ADD CONSTRAINT "currencies_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."currencies"
    ADD CONSTRAINT "currencies_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."currencies"
    ADD CONSTRAINT "currencies_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."email_logs"
    ADD CONSTRAINT "email_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."email_queue"
    ADD CONSTRAINT "email_queue_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."email_templates"
    ADD CONSTRAINT "email_templates_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."error_logs"
    ADD CONSTRAINT "error_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."exchange_rates"
    ADD CONSTRAINT "exchange_rates_base_currency_code_target_currency_code_key" UNIQUE ("base_currency_code", "target_currency_code");



ALTER TABLE ONLY "public"."exchange_rates"
    ADD CONSTRAINT "exchange_rates_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."generic_taxes"
    ADD CONSTRAINT "generic_taxes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."global_settings"
    ADD CONSTRAINT "global_settings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."integration_auth_methods"
    ADD CONSTRAINT "integration_auth_methods_method_key" UNIQUE ("method");



ALTER TABLE ONLY "public"."integration_auth_methods"
    ADD CONSTRAINT "integration_auth_methods_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."integration_body_formats"
    ADD CONSTRAINT "integration_body_formats_format_key" UNIQUE ("format");



ALTER TABLE ONLY "public"."integration_body_formats"
    ADD CONSTRAINT "integration_body_formats_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."integration_categories"
    ADD CONSTRAINT "integration_categories_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."integration_categories"
    ADD CONSTRAINT "integration_categories_slug_key" UNIQUE ("slug");



ALTER TABLE ONLY "public"."integration_http_methods"
    ADD CONSTRAINT "integration_http_methods_method_key" UNIQUE ("method");



ALTER TABLE ONLY "public"."integration_http_methods"
    ADD CONSTRAINT "integration_http_methods_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."integration_providers"
    ADD CONSTRAINT "integration_providers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."integration_providers"
    ADD CONSTRAINT "integration_providers_slug_key" UNIQUE ("slug");



ALTER TABLE ONLY "public"."integrations_config"
    ADD CONSTRAINT "integrations_config_pkey" PRIMARY KEY ("key");



ALTER TABLE ONLY "public"."investor_platform_shares"
    ADD CONSTRAINT "investor_platform_shares_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."investor_platform_stakes"
    ADD CONSTRAINT "investor_platform_stakes_investor_user_id_platform_id_key" UNIQUE ("investor_user_id", "platform_id");



ALTER TABLE ONLY "public"."investor_platform_stakes"
    ADD CONSTRAINT "investor_platform_stakes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."languages"
    ADD CONSTRAINT "languages_iso_code_key" UNIQUE ("iso_code");



ALTER TABLE ONLY "public"."languages"
    ADD CONSTRAINT "languages_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."languages"
    ADD CONSTRAINT "languages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."monthly_charges"
    ADD CONSTRAINT "monthly_charges_billing_period_unique" UNIQUE ("tenant_id", "billing_period_start");



ALTER TABLE ONLY "public"."monthly_charges"
    ADD CONSTRAINT "monthly_charges_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."payment_intents"
    ADD CONSTRAINT "payment_intents_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."payment_intents"
    ADD CONSTRAINT "payment_intents_reference_key" UNIQUE ("reference");



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."phone_prefixes"
    ADD CONSTRAINT "phone_prefixes_iso_code_key" UNIQUE ("iso_code");



ALTER TABLE ONLY "public"."phone_prefixes"
    ADD CONSTRAINT "phone_prefixes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."plan_asset_bonuses"
    ADD CONSTRAINT "plan_asset_bonuses_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."plan_asset_limits"
    ADD CONSTRAINT "plan_asset_limits_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."plan_asset_limits"
    ADD CONSTRAINT "plan_asset_limits_unique_asset_per_config" UNIQUE ("plan_country_config_id", "asset_id");



ALTER TABLE ONLY "public"."plan_assets"
    ADD CONSTRAINT "plan_assets_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."plan_country_configurations"
    ADD CONSTRAINT "plan_country_configurations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."plan_country_configurations"
    ADD CONSTRAINT "plan_country_configurations_unique" UNIQUE ("plan_id", "country_id");



ALTER TABLE ONLY "public"."platform_assignments"
    ADD CONSTRAINT "platform_assignments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."platform_assignments"
    ADD CONSTRAINT "platform_assignments_user_id_platform_id_role_id_key" UNIQUE ("user_id", "platform_id", "role_id");



ALTER TABLE ONLY "public"."platform_countries"
    ADD CONSTRAINT "platform_countries_pkey" PRIMARY KEY ("platform_id", "country_id");



ALTER TABLE ONLY "public"."platforms"
    ADD CONSTRAINT "platforms_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."platforms"
    ADD CONSTRAINT "platforms_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."price_tariffs"
    ADD CONSTRAINT "price_tariffs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."roles"
    ADD CONSTRAINT "roles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."subscription_assets"
    ADD CONSTRAINT "subscription_assets_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."subscription_items"
    ADD CONSTRAINT "subscription_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."subscription_plans"
    ADD CONSTRAINT "subscription_plans_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."system_alerts"
    ADD CONSTRAINT "system_alerts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tariff_asset_prices"
    ADD CONSTRAINT "tariff_asset_prices_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tenant_integrations"
    ADD CONSTRAINT "tenant_integrations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tenant_settings"
    ADD CONSTRAINT "tenant_settings_pkey" PRIMARY KEY ("tenant_id");



ALTER TABLE ONLY "public"."tenant_subscriptions"
    ADD CONSTRAINT "tenant_subscriptions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tenant_subscriptions"
    ADD CONSTRAINT "tenant_subscriptions_tenant_id_pcc_id_start_date_key" UNIQUE ("tenant_id", "plan_country_configuration_id", "start_date");



ALTER TABLE ONLY "public"."tenant_template_settings"
    ADD CONSTRAINT "tenant_template_settings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tenants"
    ADD CONSTRAINT "tenants_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."timezones"
    ADD CONSTRAINT "timezones_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."timezones"
    ADD CONSTRAINT "timezones_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."translations"
    ADD CONSTRAINT "translations_language_id_key_key" UNIQUE ("language_id", "key");



ALTER TABLE ONLY "public"."translations"
    ADD CONSTRAINT "translations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tariff_asset_prices"
    ADD CONSTRAINT "unique_asset_for_tariff" UNIQUE ("tariff_id", "asset_id");



ALTER TABLE ONLY "public"."plan_assets"
    ADD CONSTRAINT "unique_asset_key_for_platform" UNIQUE ("platform_id", "asset_key");



ALTER TABLE ONLY "public"."price_tariffs"
    ADD CONSTRAINT "unique_effective_date_for_plan" UNIQUE ("subscription_plan_id", "effective_date");



ALTER TABLE ONLY "public"."tenants"
    ADD CONSTRAINT "unique_platform_country_slug" UNIQUE ("platform_id", "country_id", "slug");



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "unique_provider_payment" UNIQUE ("provider", "provider_payment_id");



ALTER TABLE ONLY "public"."generic_taxes"
    ADD CONSTRAINT "unique_tax_per_country" UNIQUE ("name", "country_id");



ALTER TABLE ONLY "public"."tenant_template_settings"
    ADD CONSTRAINT "unique_template_per_tenant" UNIQUE ("tenant_id", "template_type");



ALTER TABLE ONLY "public"."tenant_integrations"
    ADD CONSTRAINT "unique_tenant_provider_environment" UNIQUE ("tenant_id", "provider", "environment");



ALTER TABLE ONLY "public"."investor_platform_shares"
    ADD CONSTRAINT "unique_user_platform_share" UNIQUE ("user_id", "platform_id");



ALTER TABLE ONLY "public"."subscription_assets"
    ADD CONSTRAINT "uq_active_asset" UNIQUE ("tenant_subscription_id", "asset_type", "asset_reference_id", "status");



ALTER TABLE ONLY "public"."vendor_platform_commissions"
    ADD CONSTRAINT "vendor_platform_commissions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."vendor_platform_commissions"
    ADD CONSTRAINT "vendor_platform_commissions_user_platform_unique" UNIQUE ("user_id", "platform_id");



ALTER TABLE ONLY "public"."vendor_tenants"
    ADD CONSTRAINT "vendor_tenants_pkey" PRIMARY KEY ("user_id", "tenant_id");



CREATE INDEX "idx_plan_assets_platform_id" ON "public"."plan_assets" USING "btree" ("platform_id");



CREATE INDEX "idx_price_tariffs_plan_id_effective_date" ON "public"."price_tariffs" USING "btree" ("subscription_plan_id", "effective_date" DESC);



CREATE INDEX "idx_subscription_plans_platform_id" ON "public"."subscription_plans" USING "btree" ("platform_id");



CREATE INDEX "idx_tariff_asset_prices_tariff_id" ON "public"."tariff_asset_prices" USING "btree" ("tariff_id");



CREATE INDEX "idx_tenant_settings_data" ON "public"."tenant_settings" USING "gin" ("settings_data");



CREATE INDEX "idx_tenants_country_id" ON "public"."tenants" USING "btree" ("country_id");



CREATE INDEX "idx_translations_context" ON "public"."translations" USING "btree" ("context");



CREATE INDEX "idx_translations_language_key" ON "public"."translations" USING "btree" ("language_id", "key");



CREATE UNIQUE INDEX "one_billing_entity_idx" ON "public"."billing_entities" USING "btree" ((1));



CREATE UNIQUE INDEX "one_default_trial_per_platform_idx" ON "public"."subscription_plans" USING "btree" ("platform_id") WHERE ("is_default_trial" = true);



CREATE UNIQUE INDEX "roles_name_global_unique_idx" ON "public"."roles" USING "btree" ("name") WHERE (("platform_id" IS NULL) AND ("tenant_id" IS NULL));



CREATE UNIQUE INDEX "roles_name_platform_unique_idx" ON "public"."roles" USING "btree" ("name", "platform_id") WHERE ("tenant_id" IS NULL);



CREATE UNIQUE INDEX "roles_name_tenant_unique_idx" ON "public"."roles" USING "btree" ("name", "tenant_id") WHERE ("tenant_id" IS NOT NULL);



CREATE UNIQUE INDEX "unique_active_integration_per_provider" ON "public"."tenant_integrations" USING "btree" ("tenant_id", "provider") WHERE ("is_active" = true);



CREATE UNIQUE INDEX "unique_owner_per_platform" ON "public"."tenants" USING "btree" ("platform_id") WHERE ("is_system_owner" = true);



ALTER TABLE ONLY "public"."asset_usage_tracking"
    ADD CONSTRAINT "asset_usage_tracking_asset_id_fkey" FOREIGN KEY ("asset_id") REFERENCES "public"."plan_assets"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."asset_usage_tracking"
    ADD CONSTRAINT "asset_usage_tracking_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."billing_entities"
    ADD CONSTRAINT "billing_entities_billing_country_id_fkey" FOREIGN KEY ("billing_country_id") REFERENCES "public"."countries"("id");



ALTER TABLE ONLY "public"."countries"
    ADD CONSTRAINT "countries_default_currency_id_fkey" FOREIGN KEY ("default_currency_id") REFERENCES "public"."currencies"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."countries"
    ADD CONSTRAINT "countries_default_language_iso_code_fkey" FOREIGN KEY ("default_language_iso_code") REFERENCES "public"."languages"("iso_code") ON UPDATE CASCADE ON DELETE SET NULL;



ALTER TABLE ONLY "public"."countries"
    ADD CONSTRAINT "countries_default_localization_id_fkey" FOREIGN KEY ("default_localization_id") REFERENCES "public"."languages"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."countries"
    ADD CONSTRAINT "countries_phone_prefix_id_fkey" FOREIGN KEY ("phone_prefix_id") REFERENCES "public"."phone_prefixes"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."country_timezones"
    ADD CONSTRAINT "country_timezones_country_id_fkey" FOREIGN KEY ("country_id") REFERENCES "public"."countries"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."country_timezones"
    ADD CONSTRAINT "country_timezones_timezone_id_fkey" FOREIGN KEY ("timezone_id") REFERENCES "public"."timezones"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."email_logs"
    ADD CONSTRAINT "email_logs_template_id_fkey" FOREIGN KEY ("template_id") REFERENCES "public"."email_templates"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."email_logs"
    ADD CONSTRAINT "email_logs_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."email_templates"
    ADD CONSTRAINT "email_templates_language_id_fkey" FOREIGN KEY ("language_id") REFERENCES "public"."languages"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."email_templates"
    ADD CONSTRAINT "email_templates_platform_id_fkey" FOREIGN KEY ("platform_id") REFERENCES "public"."platforms"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."email_templates"
    ADD CONSTRAINT "email_templates_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."error_logs"
    ADD CONSTRAINT "error_logs_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."plan_assets"
    ADD CONSTRAINT "fk_asset_purpose" FOREIGN KEY ("asset_purpose_id") REFERENCES "public"."asset_purposes"("id");



ALTER TABLE ONLY "public"."integration_providers"
    ADD CONSTRAINT "fk_auth_method" FOREIGN KEY ("auth_method_id") REFERENCES "public"."integration_auth_methods"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."integration_providers"
    ADD CONSTRAINT "fk_body_format" FOREIGN KEY ("body_format_id") REFERENCES "public"."integration_body_formats"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."integration_providers"
    ADD CONSTRAINT "fk_category" FOREIGN KEY ("category_id") REFERENCES "public"."integration_categories"("id");



ALTER TABLE ONLY "public"."integration_providers"
    ADD CONSTRAINT "fk_country" FOREIGN KEY ("country_id") REFERENCES "public"."countries"("id");



ALTER TABLE ONLY "public"."integration_providers"
    ADD CONSTRAINT "fk_http_method" FOREIGN KEY ("http_method_id") REFERENCES "public"."integration_http_methods"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."subscription_plans"
    ADD CONSTRAINT "fk_platform" FOREIGN KEY ("platform_id") REFERENCES "public"."platforms"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."system_alerts"
    ADD CONSTRAINT "fk_platform" FOREIGN KEY ("platform_id") REFERENCES "public"."platforms"("id");



ALTER TABLE ONLY "public"."generic_taxes"
    ADD CONSTRAINT "generic_taxes_country_id_fkey" FOREIGN KEY ("country_id") REFERENCES "public"."countries"("id");



ALTER TABLE ONLY "public"."global_settings"
    ADD CONSTRAINT "global_settings_base_currency_id_fkey" FOREIGN KEY ("base_currency_id") REFERENCES "public"."currencies"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."investor_platform_shares"
    ADD CONSTRAINT "investor_platform_shares_platform_id_fkey" FOREIGN KEY ("platform_id") REFERENCES "public"."platforms"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."investor_platform_shares"
    ADD CONSTRAINT "investor_platform_shares_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."investor_platform_stakes"
    ADD CONSTRAINT "investor_platform_stakes_investor_user_id_fkey" FOREIGN KEY ("investor_user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."investor_platform_stakes"
    ADD CONSTRAINT "investor_platform_stakes_platform_id_fkey" FOREIGN KEY ("platform_id") REFERENCES "public"."platforms"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."monthly_charges"
    ADD CONSTRAINT "monthly_charges_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."payment_intents"
    ADD CONSTRAINT "payment_intents_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."plan_asset_bonuses"
    ADD CONSTRAINT "plan_asset_bonuses_bonus_asset_fkey" FOREIGN KEY ("bonus_asset_id") REFERENCES "public"."plan_assets"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."plan_asset_bonuses"
    ADD CONSTRAINT "plan_asset_bonuses_source_limit_fkey" FOREIGN KEY ("source_asset_limit_id") REFERENCES "public"."plan_asset_limits"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."plan_asset_limits"
    ADD CONSTRAINT "plan_asset_limits_asset_id_fkey" FOREIGN KEY ("asset_id") REFERENCES "public"."plan_assets"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."plan_asset_limits"
    ADD CONSTRAINT "plan_asset_limits_config_id_fkey" FOREIGN KEY ("plan_country_config_id") REFERENCES "public"."plan_country_configurations"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."plan_assets"
    ADD CONSTRAINT "plan_assets_platform_id_fkey" FOREIGN KEY ("platform_id") REFERENCES "public"."platforms"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."plan_country_configurations"
    ADD CONSTRAINT "plan_country_configurations_country_id_fkey" FOREIGN KEY ("country_id") REFERENCES "public"."countries"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."plan_country_configurations"
    ADD CONSTRAINT "plan_country_configurations_plan_id_fkey" FOREIGN KEY ("plan_id") REFERENCES "public"."subscription_plans"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."platform_assignments"
    ADD CONSTRAINT "platform_assignments_platform_id_fkey" FOREIGN KEY ("platform_id") REFERENCES "public"."platforms"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."platform_assignments"
    ADD CONSTRAINT "platform_assignments_role_id_fkey" FOREIGN KEY ("role_id") REFERENCES "public"."roles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."platform_assignments"
    ADD CONSTRAINT "platform_assignments_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."platform_countries"
    ADD CONSTRAINT "platform_countries_country_id_fkey" FOREIGN KEY ("country_id") REFERENCES "public"."countries"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."platform_countries"
    ADD CONSTRAINT "platform_countries_platform_id_fkey" FOREIGN KEY ("platform_id") REFERENCES "public"."platforms"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."platforms"
    ADD CONSTRAINT "platforms_default_currency_id_fkey" FOREIGN KEY ("default_currency_id") REFERENCES "public"."currencies"("id");



ALTER TABLE ONLY "public"."platforms"
    ADD CONSTRAINT "platforms_default_language_id_fkey" FOREIGN KEY ("default_language_id") REFERENCES "public"."languages"("id");



ALTER TABLE ONLY "public"."price_tariffs"
    ADD CONSTRAINT "price_tariffs_currency_id_fkey" FOREIGN KEY ("currency_id") REFERENCES "public"."currencies"("id");



ALTER TABLE ONLY "public"."price_tariffs"
    ADD CONSTRAINT "price_tariffs_subscription_plan_id_fkey" FOREIGN KEY ("subscription_plan_id") REFERENCES "public"."subscription_plans"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."roles"
    ADD CONSTRAINT "roles_platform_id_fkey" FOREIGN KEY ("platform_id") REFERENCES "public"."platforms"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."roles"
    ADD CONSTRAINT "roles_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."subscription_assets"
    ADD CONSTRAINT "subscription_assets_tenant_subscription_id_fkey" FOREIGN KEY ("tenant_subscription_id") REFERENCES "public"."tenant_subscriptions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."subscription_items"
    ADD CONSTRAINT "subscription_items_subscription_id_fkey" FOREIGN KEY ("subscription_id") REFERENCES "public"."tenant_subscriptions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."system_alerts"
    ADD CONSTRAINT "system_alerts_resolved_by_fkey" FOREIGN KEY ("resolved_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."tariff_asset_prices"
    ADD CONSTRAINT "tariff_asset_prices_asset_id_fkey" FOREIGN KEY ("asset_id") REFERENCES "public"."plan_assets"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tariff_asset_prices"
    ADD CONSTRAINT "tariff_asset_prices_tariff_id_fkey" FOREIGN KEY ("tariff_id") REFERENCES "public"."price_tariffs"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tenant_integrations"
    ADD CONSTRAINT "tenant_integrations_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tenant_settings"
    ADD CONSTRAINT "tenant_settings_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tenant_subscriptions"
    ADD CONSTRAINT "tenant_subscriptions_plan_country_configuration_id_fkey" FOREIGN KEY ("plan_country_configuration_id") REFERENCES "public"."plan_country_configurations"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."tenant_subscriptions"
    ADD CONSTRAINT "tenant_subscriptions_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tenant_template_settings"
    ADD CONSTRAINT "tenant_template_settings_template_id_fkey" FOREIGN KEY ("template_id") REFERENCES "public"."email_templates"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."tenant_template_settings"
    ADD CONSTRAINT "tenant_template_settings_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tenants"
    ADD CONSTRAINT "tenants_country_id_fkey" FOREIGN KEY ("country_id") REFERENCES "public"."countries"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."tenants"
    ADD CONSTRAINT "tenants_default_currency_id_fkey" FOREIGN KEY ("default_currency_id") REFERENCES "public"."currencies"("id") ON UPDATE CASCADE ON DELETE SET NULL;



ALTER TABLE ONLY "public"."tenants"
    ADD CONSTRAINT "tenants_platform_id_fkey" FOREIGN KEY ("platform_id") REFERENCES "public"."platforms"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."translations"
    ADD CONSTRAINT "translations_language_id_fkey" FOREIGN KEY ("language_id") REFERENCES "public"."languages"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."translations"
    ADD CONSTRAINT "translations_platform_id_fkey" FOREIGN KEY ("platform_id") REFERENCES "public"."platforms"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."vendor_platform_commissions"
    ADD CONSTRAINT "vendor_platform_commissions_platform_id_fkey" FOREIGN KEY ("platform_id") REFERENCES "public"."platforms"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."vendor_platform_commissions"
    ADD CONSTRAINT "vendor_platform_commissions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."vendor_tenants"
    ADD CONSTRAINT "vendor_tenants_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."vendor_tenants"
    ADD CONSTRAINT "vendor_tenants_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



CREATE POLICY "Allow ALL for super_admin" ON "public"."asset_purposes" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."asset_usage_tracking" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."billing_entities" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."countries" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."country_timezones" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."currencies" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."email_logs" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."email_queue" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."email_templates" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."error_logs" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."exchange_rates" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."generic_taxes" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."global_settings" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."integration_auth_methods" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."integration_body_formats" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."integration_categories" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."integration_http_methods" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."integration_providers" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."integrations_config" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."investor_platform_shares" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."investor_platform_stakes" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."languages" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."monthly_charges" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."payment_intents" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."payments" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."phone_prefixes" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."plan_asset_bonuses" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."plan_asset_limits" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."plan_assets" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."plan_country_configurations" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."platform_assignments" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."platform_countries" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."platforms" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."price_tariffs" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."roles" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."subscription_assets" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."subscription_items" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."subscription_plans" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."system_alerts" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."tariff_asset_prices" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."tenant_integrations" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."tenant_settings" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."tenant_subscriptions" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."tenant_template_settings" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."tenants" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."timezones" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."translations" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."vendor_platform_commissions" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow ALL for super_admin" ON "public"."vendor_tenants" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "Allow public read access" ON "public"."countries" FOR SELECT USING (true);



CREATE POLICY "Allow public read access" ON "public"."currencies" FOR SELECT USING (true);



CREATE POLICY "Allow public read access" ON "public"."languages" FOR SELECT USING (true);



CREATE POLICY "Allow public read access" ON "public"."phone_prefixes" FOR SELECT USING (true);



CREATE POLICY "Allow public read access" ON "public"."platforms" FOR SELECT USING (true);



CREATE POLICY "Allow tenant members read access" ON "public"."tenant_subscriptions" FOR SELECT USING (("tenant_id" = "public"."get_current_tenant_id"()));



CREATE POLICY "Allow tenant members read access" ON "public"."tenants" FOR SELECT USING (("id" = "public"."get_current_tenant_id"()));



ALTER TABLE "public"."asset_purposes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."asset_usage_tracking" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."billing_entities" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."countries" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."country_timezones" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."currencies" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."email_logs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."email_queue" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."email_templates" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."error_logs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."exchange_rates" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."generic_taxes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."global_settings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."integration_auth_methods" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."integration_body_formats" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."integration_categories" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."integration_http_methods" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."integration_providers" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."integration_record" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."integrations_config" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."investor_platform_shares" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."investor_platform_stakes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."languages" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."monthly_charges" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."payment_intents" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."payments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."phone_prefixes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."plan_asset_bonuses" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."plan_asset_limits" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."plan_assets" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."plan_country_configurations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."platform_assignments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."platform_countries" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."platforms" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."price_tariffs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."roles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."subscription_assets" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."subscription_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."subscription_plans" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."system_alerts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."tariff_asset_prices" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."tenant_integrations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."tenant_settings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."tenant_subscriptions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."tenant_template_settings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."tenants" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."timezones" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."translations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."vendor_platform_commissions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."vendor_tenants" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";





GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";






GRANT ALL ON FUNCTION "public"."gbtreekey16_in"("cstring") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey16_in"("cstring") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey16_in"("cstring") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey16_in"("cstring") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey16_out"("public"."gbtreekey16") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey16_out"("public"."gbtreekey16") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey16_out"("public"."gbtreekey16") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey16_out"("public"."gbtreekey16") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey2_in"("cstring") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey2_in"("cstring") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey2_in"("cstring") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey2_in"("cstring") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey2_out"("public"."gbtreekey2") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey2_out"("public"."gbtreekey2") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey2_out"("public"."gbtreekey2") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey2_out"("public"."gbtreekey2") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey32_in"("cstring") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey32_in"("cstring") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey32_in"("cstring") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey32_in"("cstring") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey32_out"("public"."gbtreekey32") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey32_out"("public"."gbtreekey32") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey32_out"("public"."gbtreekey32") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey32_out"("public"."gbtreekey32") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey4_in"("cstring") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey4_in"("cstring") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey4_in"("cstring") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey4_in"("cstring") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey4_out"("public"."gbtreekey4") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey4_out"("public"."gbtreekey4") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey4_out"("public"."gbtreekey4") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey4_out"("public"."gbtreekey4") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey8_in"("cstring") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey8_in"("cstring") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey8_in"("cstring") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey8_in"("cstring") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey8_out"("public"."gbtreekey8") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey8_out"("public"."gbtreekey8") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey8_out"("public"."gbtreekey8") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey8_out"("public"."gbtreekey8") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey_var_in"("cstring") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey_var_in"("cstring") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey_var_in"("cstring") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey_var_in"("cstring") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey_var_out"("public"."gbtreekey_var") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey_var_out"("public"."gbtreekey_var") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey_var_out"("public"."gbtreekey_var") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey_var_out"("public"."gbtreekey_var") TO "service_role";














































































































































































GRANT ALL ON FUNCTION "public"."algorithm_sign"("signables" "text", "secret" "text", "algorithm" "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."algorithm_sign"("signables" "text", "secret" "text", "algorithm" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."algorithm_sign"("signables" "text", "secret" "text", "algorithm" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."algorithm_sign"("signables" "text", "secret" "text", "algorithm" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."bytea_to_text"("data" "bytea") TO "postgres";
GRANT ALL ON FUNCTION "public"."bytea_to_text"("data" "bytea") TO "anon";
GRANT ALL ON FUNCTION "public"."bytea_to_text"("data" "bytea") TO "authenticated";
GRANT ALL ON FUNCTION "public"."bytea_to_text"("data" "bytea") TO "service_role";



GRANT ALL ON FUNCTION "public"."cash_dist"("money", "money") TO "postgres";
GRANT ALL ON FUNCTION "public"."cash_dist"("money", "money") TO "anon";
GRANT ALL ON FUNCTION "public"."cash_dist"("money", "money") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cash_dist"("money", "money") TO "service_role";



GRANT ALL ON FUNCTION "public"."check_superadmin_exists"() TO "anon";
GRANT ALL ON FUNCTION "public"."check_superadmin_exists"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."check_superadmin_exists"() TO "service_role";



GRANT ALL ON FUNCTION "public"."clone_configurations_from_platform"("p_source_platform_id" "uuid", "p_target_platform_id" "uuid", "p_config_to_clone" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."clone_configurations_from_platform"("p_source_platform_id" "uuid", "p_target_platform_id" "uuid", "p_config_to_clone" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."clone_configurations_from_platform"("p_source_platform_id" "uuid", "p_target_platform_id" "uuid", "p_config_to_clone" "text"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."date_dist"("date", "date") TO "postgres";
GRANT ALL ON FUNCTION "public"."date_dist"("date", "date") TO "anon";
GRANT ALL ON FUNCTION "public"."date_dist"("date", "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."date_dist"("date", "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."float4_dist"(real, real) TO "postgres";
GRANT ALL ON FUNCTION "public"."float4_dist"(real, real) TO "anon";
GRANT ALL ON FUNCTION "public"."float4_dist"(real, real) TO "authenticated";
GRANT ALL ON FUNCTION "public"."float4_dist"(real, real) TO "service_role";



GRANT ALL ON FUNCTION "public"."float8_dist"(double precision, double precision) TO "postgres";
GRANT ALL ON FUNCTION "public"."float8_dist"(double precision, double precision) TO "anon";
GRANT ALL ON FUNCTION "public"."float8_dist"(double precision, double precision) TO "authenticated";
GRANT ALL ON FUNCTION "public"."float8_dist"(double precision, double precision) TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bit_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bit_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bit_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bit_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bit_consistent"("internal", bit, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bit_consistent"("internal", bit, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bit_consistent"("internal", bit, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bit_consistent"("internal", bit, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bit_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bit_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bit_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bit_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bit_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bit_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bit_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bit_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bit_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bit_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bit_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bit_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bit_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bit_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bit_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bit_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bool_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bool_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bool_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bool_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bool_consistent"("internal", boolean, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bool_consistent"("internal", boolean, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bool_consistent"("internal", boolean, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bool_consistent"("internal", boolean, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bool_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bool_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bool_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bool_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bool_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bool_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bool_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bool_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bool_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bool_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bool_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bool_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bool_same"("public"."gbtreekey2", "public"."gbtreekey2", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bool_same"("public"."gbtreekey2", "public"."gbtreekey2", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bool_same"("public"."gbtreekey2", "public"."gbtreekey2", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bool_same"("public"."gbtreekey2", "public"."gbtreekey2", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bool_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bool_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bool_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bool_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bpchar_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bpchar_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bpchar_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bpchar_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bpchar_consistent"("internal", character, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bpchar_consistent"("internal", character, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bpchar_consistent"("internal", character, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bpchar_consistent"("internal", character, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bytea_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bytea_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bytea_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bytea_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bytea_consistent"("internal", "bytea", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bytea_consistent"("internal", "bytea", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bytea_consistent"("internal", "bytea", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bytea_consistent"("internal", "bytea", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bytea_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bytea_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bytea_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bytea_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bytea_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bytea_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bytea_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bytea_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bytea_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bytea_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bytea_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bytea_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bytea_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bytea_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bytea_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bytea_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_cash_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_cash_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_cash_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_cash_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_cash_consistent"("internal", "money", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_cash_consistent"("internal", "money", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_cash_consistent"("internal", "money", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_cash_consistent"("internal", "money", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_cash_distance"("internal", "money", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_cash_distance"("internal", "money", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_cash_distance"("internal", "money", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_cash_distance"("internal", "money", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_cash_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_cash_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_cash_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_cash_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_cash_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_cash_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_cash_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_cash_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_cash_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_cash_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_cash_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_cash_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_cash_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_cash_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_cash_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_cash_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_cash_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_cash_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_cash_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_cash_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_date_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_date_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_date_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_date_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_date_consistent"("internal", "date", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_date_consistent"("internal", "date", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_date_consistent"("internal", "date", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_date_consistent"("internal", "date", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_date_distance"("internal", "date", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_date_distance"("internal", "date", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_date_distance"("internal", "date", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_date_distance"("internal", "date", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_date_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_date_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_date_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_date_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_date_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_date_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_date_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_date_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_date_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_date_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_date_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_date_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_date_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_date_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_date_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_date_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_date_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_date_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_date_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_date_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_decompress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_decompress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_decompress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_decompress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_enum_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_enum_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_enum_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_enum_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_enum_consistent"("internal", "anyenum", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_enum_consistent"("internal", "anyenum", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_enum_consistent"("internal", "anyenum", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_enum_consistent"("internal", "anyenum", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_enum_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_enum_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_enum_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_enum_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_enum_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_enum_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_enum_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_enum_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_enum_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_enum_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_enum_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_enum_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_enum_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_enum_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_enum_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_enum_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_enum_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_enum_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_enum_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_enum_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float4_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float4_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float4_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float4_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float4_consistent"("internal", real, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float4_consistent"("internal", real, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float4_consistent"("internal", real, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float4_consistent"("internal", real, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float4_distance"("internal", real, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float4_distance"("internal", real, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float4_distance"("internal", real, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float4_distance"("internal", real, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float4_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float4_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float4_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float4_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float4_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float4_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float4_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float4_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float4_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float4_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float4_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float4_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float4_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float4_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float4_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float4_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float4_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float4_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float4_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float4_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float8_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float8_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float8_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float8_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float8_consistent"("internal", double precision, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float8_consistent"("internal", double precision, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float8_consistent"("internal", double precision, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float8_consistent"("internal", double precision, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float8_distance"("internal", double precision, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float8_distance"("internal", double precision, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float8_distance"("internal", double precision, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float8_distance"("internal", double precision, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float8_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float8_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float8_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float8_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float8_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float8_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float8_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float8_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float8_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float8_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float8_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float8_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float8_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float8_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float8_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float8_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_inet_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_inet_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_inet_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_inet_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_inet_consistent"("internal", "inet", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_inet_consistent"("internal", "inet", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_inet_consistent"("internal", "inet", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_inet_consistent"("internal", "inet", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_inet_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_inet_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_inet_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_inet_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_inet_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_inet_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_inet_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_inet_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_inet_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_inet_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_inet_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_inet_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_inet_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_inet_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_inet_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_inet_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int2_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int2_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int2_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int2_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int2_consistent"("internal", smallint, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int2_consistent"("internal", smallint, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int2_consistent"("internal", smallint, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int2_consistent"("internal", smallint, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int2_distance"("internal", smallint, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int2_distance"("internal", smallint, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int2_distance"("internal", smallint, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int2_distance"("internal", smallint, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int2_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int2_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int2_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int2_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int2_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int2_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int2_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int2_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int2_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int2_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int2_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int2_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int2_same"("public"."gbtreekey4", "public"."gbtreekey4", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int2_same"("public"."gbtreekey4", "public"."gbtreekey4", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int2_same"("public"."gbtreekey4", "public"."gbtreekey4", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int2_same"("public"."gbtreekey4", "public"."gbtreekey4", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int2_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int2_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int2_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int2_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int4_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int4_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int4_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int4_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int4_consistent"("internal", integer, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int4_consistent"("internal", integer, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int4_consistent"("internal", integer, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int4_consistent"("internal", integer, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int4_distance"("internal", integer, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int4_distance"("internal", integer, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int4_distance"("internal", integer, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int4_distance"("internal", integer, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int4_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int4_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int4_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int4_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int4_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int4_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int4_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int4_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int4_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int4_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int4_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int4_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int4_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int4_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int4_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int4_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int4_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int4_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int4_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int4_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int8_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int8_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int8_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int8_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int8_consistent"("internal", bigint, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int8_consistent"("internal", bigint, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int8_consistent"("internal", bigint, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int8_consistent"("internal", bigint, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int8_distance"("internal", bigint, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int8_distance"("internal", bigint, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int8_distance"("internal", bigint, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int8_distance"("internal", bigint, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int8_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int8_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int8_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int8_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int8_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int8_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int8_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int8_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int8_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int8_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int8_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int8_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int8_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int8_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int8_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int8_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_intv_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_intv_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_intv_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_intv_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_intv_consistent"("internal", interval, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_intv_consistent"("internal", interval, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_intv_consistent"("internal", interval, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_intv_consistent"("internal", interval, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_intv_decompress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_intv_decompress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_intv_decompress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_intv_decompress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_intv_distance"("internal", interval, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_intv_distance"("internal", interval, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_intv_distance"("internal", interval, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_intv_distance"("internal", interval, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_intv_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_intv_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_intv_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_intv_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_intv_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_intv_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_intv_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_intv_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_intv_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_intv_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_intv_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_intv_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_intv_same"("public"."gbtreekey32", "public"."gbtreekey32", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_intv_same"("public"."gbtreekey32", "public"."gbtreekey32", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_intv_same"("public"."gbtreekey32", "public"."gbtreekey32", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_intv_same"("public"."gbtreekey32", "public"."gbtreekey32", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_intv_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_intv_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_intv_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_intv_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad8_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad8_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad8_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad8_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad8_consistent"("internal", "macaddr8", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad8_consistent"("internal", "macaddr8", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad8_consistent"("internal", "macaddr8", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad8_consistent"("internal", "macaddr8", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad8_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad8_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad8_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad8_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad8_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad8_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad8_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad8_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad8_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad8_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad8_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad8_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad8_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad8_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad8_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad8_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad_consistent"("internal", "macaddr", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad_consistent"("internal", "macaddr", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad_consistent"("internal", "macaddr", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad_consistent"("internal", "macaddr", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_numeric_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_numeric_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_numeric_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_numeric_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_numeric_consistent"("internal", numeric, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_numeric_consistent"("internal", numeric, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_numeric_consistent"("internal", numeric, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_numeric_consistent"("internal", numeric, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_numeric_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_numeric_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_numeric_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_numeric_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_numeric_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_numeric_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_numeric_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_numeric_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_numeric_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_numeric_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_numeric_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_numeric_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_numeric_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_numeric_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_numeric_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_numeric_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_oid_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_oid_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_oid_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_oid_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_oid_consistent"("internal", "oid", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_oid_consistent"("internal", "oid", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_oid_consistent"("internal", "oid", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_oid_consistent"("internal", "oid", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_oid_distance"("internal", "oid", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_oid_distance"("internal", "oid", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_oid_distance"("internal", "oid", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_oid_distance"("internal", "oid", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_oid_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_oid_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_oid_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_oid_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_oid_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_oid_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_oid_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_oid_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_oid_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_oid_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_oid_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_oid_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_oid_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_oid_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_oid_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_oid_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_oid_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_oid_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_oid_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_oid_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_text_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_text_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_text_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_text_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_text_consistent"("internal", "text", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_text_consistent"("internal", "text", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_text_consistent"("internal", "text", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_text_consistent"("internal", "text", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_text_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_text_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_text_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_text_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_text_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_text_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_text_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_text_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_text_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_text_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_text_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_text_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_text_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_text_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_text_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_text_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_time_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_time_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_time_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_time_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_time_consistent"("internal", time without time zone, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_time_consistent"("internal", time without time zone, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_time_consistent"("internal", time without time zone, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_time_consistent"("internal", time without time zone, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_time_distance"("internal", time without time zone, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_time_distance"("internal", time without time zone, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_time_distance"("internal", time without time zone, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_time_distance"("internal", time without time zone, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_time_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_time_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_time_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_time_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_time_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_time_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_time_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_time_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_time_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_time_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_time_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_time_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_time_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_time_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_time_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_time_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_time_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_time_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_time_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_time_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_timetz_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_timetz_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_timetz_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_timetz_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_timetz_consistent"("internal", time with time zone, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_timetz_consistent"("internal", time with time zone, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_timetz_consistent"("internal", time with time zone, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_timetz_consistent"("internal", time with time zone, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_ts_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_ts_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_ts_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_ts_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_ts_consistent"("internal", timestamp without time zone, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_ts_consistent"("internal", timestamp without time zone, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_ts_consistent"("internal", timestamp without time zone, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_ts_consistent"("internal", timestamp without time zone, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_ts_distance"("internal", timestamp without time zone, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_ts_distance"("internal", timestamp without time zone, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_ts_distance"("internal", timestamp without time zone, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_ts_distance"("internal", timestamp without time zone, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_ts_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_ts_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_ts_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_ts_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_ts_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_ts_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_ts_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_ts_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_ts_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_ts_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_ts_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_ts_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_ts_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_ts_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_ts_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_ts_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_ts_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_ts_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_ts_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_ts_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_tstz_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_tstz_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_tstz_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_tstz_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_tstz_consistent"("internal", timestamp with time zone, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_tstz_consistent"("internal", timestamp with time zone, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_tstz_consistent"("internal", timestamp with time zone, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_tstz_consistent"("internal", timestamp with time zone, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_tstz_distance"("internal", timestamp with time zone, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_tstz_distance"("internal", timestamp with time zone, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_tstz_distance"("internal", timestamp with time zone, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_tstz_distance"("internal", timestamp with time zone, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_uuid_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_uuid_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_uuid_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_uuid_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_uuid_consistent"("internal", "uuid", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_uuid_consistent"("internal", "uuid", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_uuid_consistent"("internal", "uuid", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_uuid_consistent"("internal", "uuid", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_uuid_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_uuid_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_uuid_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_uuid_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_uuid_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_uuid_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_uuid_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_uuid_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_uuid_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_uuid_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_uuid_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_uuid_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_uuid_same"("public"."gbtreekey32", "public"."gbtreekey32", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_uuid_same"("public"."gbtreekey32", "public"."gbtreekey32", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_uuid_same"("public"."gbtreekey32", "public"."gbtreekey32", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_uuid_same"("public"."gbtreekey32", "public"."gbtreekey32", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_uuid_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_uuid_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_uuid_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_uuid_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_var_decompress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_var_decompress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_var_decompress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_var_decompress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_var_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_var_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_var_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_var_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_calculated_plan_prices"("p_platform_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_calculated_plan_prices"("p_platform_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_calculated_plan_prices"("p_platform_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_current_role_name"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_current_role_name"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_current_role_name"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_current_tenant_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_current_tenant_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_current_tenant_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_platform_financial_stats"("p_platform_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_platform_financial_stats"("p_platform_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_platform_financial_stats"("p_platform_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_platform_level_assignments"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_platform_level_assignments"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_platform_level_assignments"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_platforms_stats"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_platforms_stats"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_platforms_stats"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_public_subscription_plans"("p_country_id" "uuid", "p_platform_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_public_subscription_plans"("p_country_id" "uuid", "p_platform_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_public_subscription_plans"("p_country_id" "uuid", "p_platform_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_subscription_plans_for_tenant"("p_tenant_id" "uuid", "p_platform_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_subscription_plans_for_tenant"("p_tenant_id" "uuid", "p_platform_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_subscription_plans_for_tenant"("p_tenant_id" "uuid", "p_platform_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_superadmin_payment_stats"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_superadmin_payment_stats"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_superadmin_payment_stats"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_tenant_for_microsite"("p_country_iso_code" "text", "p_slug" "text", "p_platform_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_tenant_for_microsite"("p_country_iso_code" "text", "p_slug" "text", "p_platform_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_tenant_for_microsite"("p_country_iso_code" "text", "p_slug" "text", "p_platform_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."http"("request" "public"."http_request") TO "postgres";
GRANT ALL ON FUNCTION "public"."http"("request" "public"."http_request") TO "anon";
GRANT ALL ON FUNCTION "public"."http"("request" "public"."http_request") TO "authenticated";
GRANT ALL ON FUNCTION "public"."http"("request" "public"."http_request") TO "service_role";



GRANT ALL ON FUNCTION "public"."http_delete"("uri" character varying) TO "postgres";
GRANT ALL ON FUNCTION "public"."http_delete"("uri" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."http_delete"("uri" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."http_delete"("uri" character varying) TO "service_role";



GRANT ALL ON FUNCTION "public"."http_delete"("uri" character varying, "content" character varying, "content_type" character varying) TO "postgres";
GRANT ALL ON FUNCTION "public"."http_delete"("uri" character varying, "content" character varying, "content_type" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."http_delete"("uri" character varying, "content" character varying, "content_type" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."http_delete"("uri" character varying, "content" character varying, "content_type" character varying) TO "service_role";



GRANT ALL ON FUNCTION "public"."http_get"("uri" character varying) TO "postgres";
GRANT ALL ON FUNCTION "public"."http_get"("uri" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."http_get"("uri" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."http_get"("uri" character varying) TO "service_role";



GRANT ALL ON FUNCTION "public"."http_get"("uri" character varying, "data" "jsonb") TO "postgres";
GRANT ALL ON FUNCTION "public"."http_get"("uri" character varying, "data" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."http_get"("uri" character varying, "data" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."http_get"("uri" character varying, "data" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."http_head"("uri" character varying) TO "postgres";
GRANT ALL ON FUNCTION "public"."http_head"("uri" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."http_head"("uri" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."http_head"("uri" character varying) TO "service_role";



GRANT ALL ON FUNCTION "public"."http_header"("field" character varying, "value" character varying) TO "postgres";
GRANT ALL ON FUNCTION "public"."http_header"("field" character varying, "value" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."http_header"("field" character varying, "value" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."http_header"("field" character varying, "value" character varying) TO "service_role";



GRANT ALL ON FUNCTION "public"."http_list_curlopt"() TO "postgres";
GRANT ALL ON FUNCTION "public"."http_list_curlopt"() TO "anon";
GRANT ALL ON FUNCTION "public"."http_list_curlopt"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."http_list_curlopt"() TO "service_role";



GRANT ALL ON FUNCTION "public"."http_patch"("uri" character varying, "content" character varying, "content_type" character varying) TO "postgres";
GRANT ALL ON FUNCTION "public"."http_patch"("uri" character varying, "content" character varying, "content_type" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."http_patch"("uri" character varying, "content" character varying, "content_type" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."http_patch"("uri" character varying, "content" character varying, "content_type" character varying) TO "service_role";



GRANT ALL ON FUNCTION "public"."http_post"("uri" character varying, "data" "jsonb") TO "postgres";
GRANT ALL ON FUNCTION "public"."http_post"("uri" character varying, "data" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."http_post"("uri" character varying, "data" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."http_post"("uri" character varying, "data" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."http_post"("uri" character varying, "content" character varying, "content_type" character varying) TO "postgres";
GRANT ALL ON FUNCTION "public"."http_post"("uri" character varying, "content" character varying, "content_type" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."http_post"("uri" character varying, "content" character varying, "content_type" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."http_post"("uri" character varying, "content" character varying, "content_type" character varying) TO "service_role";



GRANT ALL ON FUNCTION "public"."http_put"("uri" character varying, "content" character varying, "content_type" character varying) TO "postgres";
GRANT ALL ON FUNCTION "public"."http_put"("uri" character varying, "content" character varying, "content_type" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."http_put"("uri" character varying, "content" character varying, "content_type" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."http_put"("uri" character varying, "content" character varying, "content_type" character varying) TO "service_role";



GRANT ALL ON FUNCTION "public"."http_reset_curlopt"() TO "postgres";
GRANT ALL ON FUNCTION "public"."http_reset_curlopt"() TO "anon";
GRANT ALL ON FUNCTION "public"."http_reset_curlopt"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."http_reset_curlopt"() TO "service_role";



GRANT ALL ON FUNCTION "public"."http_set_curlopt"("curlopt" character varying, "value" character varying) TO "postgres";
GRANT ALL ON FUNCTION "public"."http_set_curlopt"("curlopt" character varying, "value" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."http_set_curlopt"("curlopt" character varying, "value" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."http_set_curlopt"("curlopt" character varying, "value" character varying) TO "service_role";



GRANT ALL ON FUNCTION "public"."int2_dist"(smallint, smallint) TO "postgres";
GRANT ALL ON FUNCTION "public"."int2_dist"(smallint, smallint) TO "anon";
GRANT ALL ON FUNCTION "public"."int2_dist"(smallint, smallint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."int2_dist"(smallint, smallint) TO "service_role";



GRANT ALL ON FUNCTION "public"."int4_dist"(integer, integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."int4_dist"(integer, integer) TO "anon";
GRANT ALL ON FUNCTION "public"."int4_dist"(integer, integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."int4_dist"(integer, integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."int8_dist"(bigint, bigint) TO "postgres";
GRANT ALL ON FUNCTION "public"."int8_dist"(bigint, bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."int8_dist"(bigint, bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."int8_dist"(bigint, bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."interval_dist"(interval, interval) TO "postgres";
GRANT ALL ON FUNCTION "public"."interval_dist"(interval, interval) TO "anon";
GRANT ALL ON FUNCTION "public"."interval_dist"(interval, interval) TO "authenticated";
GRANT ALL ON FUNCTION "public"."interval_dist"(interval, interval) TO "service_role";



GRANT ALL ON FUNCTION "public"."invoke_core_orphan_cleanup"() TO "anon";
GRANT ALL ON FUNCTION "public"."invoke_core_orphan_cleanup"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."invoke_core_orphan_cleanup"() TO "service_role";



GRANT ALL ON FUNCTION "public"."is_super_admin"() TO "anon";
GRANT ALL ON FUNCTION "public"."is_super_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_super_admin"() TO "service_role";



GRANT ALL ON FUNCTION "public"."moddatetime"() TO "postgres";
GRANT ALL ON FUNCTION "public"."moddatetime"() TO "anon";
GRANT ALL ON FUNCTION "public"."moddatetime"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."moddatetime"() TO "service_role";



GRANT ALL ON FUNCTION "public"."oid_dist"("oid", "oid") TO "postgres";
GRANT ALL ON FUNCTION "public"."oid_dist"("oid", "oid") TO "anon";
GRANT ALL ON FUNCTION "public"."oid_dist"("oid", "oid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."oid_dist"("oid", "oid") TO "service_role";



GRANT ALL ON FUNCTION "public"."sign"("payload" json, "secret" "text", "algorithm" "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."sign"("payload" json, "secret" "text", "algorithm" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."sign"("payload" json, "secret" "text", "algorithm" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sign"("payload" json, "secret" "text", "algorithm" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."text_to_bytea"("data" "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."text_to_bytea"("data" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."text_to_bytea"("data" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."text_to_bytea"("data" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."time_dist"(time without time zone, time without time zone) TO "postgres";
GRANT ALL ON FUNCTION "public"."time_dist"(time without time zone, time without time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."time_dist"(time without time zone, time without time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."time_dist"(time without time zone, time without time zone) TO "service_role";



GRANT ALL ON FUNCTION "public"."try_cast_double"("inp" "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."try_cast_double"("inp" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."try_cast_double"("inp" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."try_cast_double"("inp" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."ts_dist"(timestamp without time zone, timestamp without time zone) TO "postgres";
GRANT ALL ON FUNCTION "public"."ts_dist"(timestamp without time zone, timestamp without time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."ts_dist"(timestamp without time zone, timestamp without time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."ts_dist"(timestamp without time zone, timestamp without time zone) TO "service_role";



GRANT ALL ON FUNCTION "public"."tstz_dist"(timestamp with time zone, timestamp with time zone) TO "postgres";
GRANT ALL ON FUNCTION "public"."tstz_dist"(timestamp with time zone, timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."tstz_dist"(timestamp with time zone, timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."tstz_dist"(timestamp with time zone, timestamp with time zone) TO "service_role";



GRANT ALL ON FUNCTION "public"."url_decode"("data" "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."url_decode"("data" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."url_decode"("data" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."url_decode"("data" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."url_encode"("data" "bytea") TO "postgres";
GRANT ALL ON FUNCTION "public"."url_encode"("data" "bytea") TO "anon";
GRANT ALL ON FUNCTION "public"."url_encode"("data" "bytea") TO "authenticated";
GRANT ALL ON FUNCTION "public"."url_encode"("data" "bytea") TO "service_role";



GRANT ALL ON FUNCTION "public"."urlencode"("string" "bytea") TO "postgres";
GRANT ALL ON FUNCTION "public"."urlencode"("string" "bytea") TO "anon";
GRANT ALL ON FUNCTION "public"."urlencode"("string" "bytea") TO "authenticated";
GRANT ALL ON FUNCTION "public"."urlencode"("string" "bytea") TO "service_role";



GRANT ALL ON FUNCTION "public"."urlencode"("data" "jsonb") TO "postgres";
GRANT ALL ON FUNCTION "public"."urlencode"("data" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."urlencode"("data" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."urlencode"("data" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."urlencode"("string" character varying) TO "postgres";
GRANT ALL ON FUNCTION "public"."urlencode"("string" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."urlencode"("string" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."urlencode"("string" character varying) TO "service_role";



GRANT ALL ON FUNCTION "public"."verify"("token" "text", "secret" "text", "algorithm" "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."verify"("token" "text", "secret" "text", "algorithm" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."verify"("token" "text", "secret" "text", "algorithm" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."verify"("token" "text", "secret" "text", "algorithm" "text") TO "service_role";
























GRANT ALL ON TABLE "public"."asset_purposes" TO "anon";
GRANT ALL ON TABLE "public"."asset_purposes" TO "authenticated";
GRANT ALL ON TABLE "public"."asset_purposes" TO "service_role";



GRANT ALL ON TABLE "public"."asset_usage_tracking" TO "anon";
GRANT ALL ON TABLE "public"."asset_usage_tracking" TO "authenticated";
GRANT ALL ON TABLE "public"."asset_usage_tracking" TO "service_role";



GRANT ALL ON SEQUENCE "public"."asset_usage_tracking_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."asset_usage_tracking_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."asset_usage_tracking_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."billing_entities" TO "anon";
GRANT ALL ON TABLE "public"."billing_entities" TO "authenticated";
GRANT ALL ON TABLE "public"."billing_entities" TO "service_role";



GRANT ALL ON TABLE "public"."countries" TO "anon";
GRANT ALL ON TABLE "public"."countries" TO "authenticated";
GRANT ALL ON TABLE "public"."countries" TO "service_role";



GRANT ALL ON TABLE "public"."country_timezones" TO "anon";
GRANT ALL ON TABLE "public"."country_timezones" TO "authenticated";
GRANT ALL ON TABLE "public"."country_timezones" TO "service_role";



GRANT ALL ON TABLE "public"."currencies" TO "anon";
GRANT ALL ON TABLE "public"."currencies" TO "authenticated";
GRANT ALL ON TABLE "public"."currencies" TO "service_role";



GRANT ALL ON TABLE "public"."email_logs" TO "anon";
GRANT ALL ON TABLE "public"."email_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."email_logs" TO "service_role";



GRANT ALL ON TABLE "public"."email_queue" TO "anon";
GRANT ALL ON TABLE "public"."email_queue" TO "authenticated";
GRANT ALL ON TABLE "public"."email_queue" TO "service_role";



GRANT ALL ON TABLE "public"."email_templates" TO "anon";
GRANT ALL ON TABLE "public"."email_templates" TO "authenticated";
GRANT ALL ON TABLE "public"."email_templates" TO "service_role";



GRANT ALL ON TABLE "public"."error_logs" TO "anon";
GRANT ALL ON TABLE "public"."error_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."error_logs" TO "service_role";



GRANT ALL ON TABLE "public"."exchange_rates" TO "anon";
GRANT ALL ON TABLE "public"."exchange_rates" TO "authenticated";
GRANT ALL ON TABLE "public"."exchange_rates" TO "service_role";



GRANT ALL ON TABLE "public"."generic_taxes" TO "anon";
GRANT ALL ON TABLE "public"."generic_taxes" TO "authenticated";
GRANT ALL ON TABLE "public"."generic_taxes" TO "service_role";



GRANT ALL ON TABLE "public"."global_settings" TO "anon";
GRANT ALL ON TABLE "public"."global_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."global_settings" TO "service_role";



GRANT ALL ON TABLE "public"."integration_auth_methods" TO "anon";
GRANT ALL ON TABLE "public"."integration_auth_methods" TO "authenticated";
GRANT ALL ON TABLE "public"."integration_auth_methods" TO "service_role";



GRANT ALL ON TABLE "public"."integration_body_formats" TO "anon";
GRANT ALL ON TABLE "public"."integration_body_formats" TO "authenticated";
GRANT ALL ON TABLE "public"."integration_body_formats" TO "service_role";



GRANT ALL ON TABLE "public"."integration_categories" TO "anon";
GRANT ALL ON TABLE "public"."integration_categories" TO "authenticated";
GRANT ALL ON TABLE "public"."integration_categories" TO "service_role";



GRANT ALL ON TABLE "public"."integration_http_methods" TO "anon";
GRANT ALL ON TABLE "public"."integration_http_methods" TO "authenticated";
GRANT ALL ON TABLE "public"."integration_http_methods" TO "service_role";



GRANT ALL ON TABLE "public"."integration_providers" TO "anon";
GRANT ALL ON TABLE "public"."integration_providers" TO "authenticated";
GRANT ALL ON TABLE "public"."integration_providers" TO "service_role";



GRANT ALL ON TABLE "public"."integration_record" TO "anon";
GRANT ALL ON TABLE "public"."integration_record" TO "authenticated";
GRANT ALL ON TABLE "public"."integration_record" TO "service_role";



GRANT ALL ON TABLE "public"."integrations_config" TO "anon";
GRANT ALL ON TABLE "public"."integrations_config" TO "authenticated";
GRANT ALL ON TABLE "public"."integrations_config" TO "service_role";



GRANT ALL ON TABLE "public"."investor_platform_shares" TO "anon";
GRANT ALL ON TABLE "public"."investor_platform_shares" TO "authenticated";
GRANT ALL ON TABLE "public"."investor_platform_shares" TO "service_role";



GRANT ALL ON TABLE "public"."investor_platform_stakes" TO "anon";
GRANT ALL ON TABLE "public"."investor_platform_stakes" TO "authenticated";
GRANT ALL ON TABLE "public"."investor_platform_stakes" TO "service_role";



GRANT ALL ON TABLE "public"."languages" TO "anon";
GRANT ALL ON TABLE "public"."languages" TO "authenticated";
GRANT ALL ON TABLE "public"."languages" TO "service_role";



GRANT ALL ON TABLE "public"."monthly_charges" TO "anon";
GRANT ALL ON TABLE "public"."monthly_charges" TO "authenticated";
GRANT ALL ON TABLE "public"."monthly_charges" TO "service_role";



GRANT ALL ON TABLE "public"."payment_intents" TO "anon";
GRANT ALL ON TABLE "public"."payment_intents" TO "authenticated";
GRANT ALL ON TABLE "public"."payment_intents" TO "service_role";



GRANT ALL ON TABLE "public"."payments" TO "anon";
GRANT ALL ON TABLE "public"."payments" TO "authenticated";
GRANT ALL ON TABLE "public"."payments" TO "service_role";



GRANT ALL ON TABLE "public"."phone_prefixes" TO "anon";
GRANT ALL ON TABLE "public"."phone_prefixes" TO "authenticated";
GRANT ALL ON TABLE "public"."phone_prefixes" TO "service_role";



GRANT ALL ON TABLE "public"."plan_asset_bonuses" TO "anon";
GRANT ALL ON TABLE "public"."plan_asset_bonuses" TO "authenticated";
GRANT ALL ON TABLE "public"."plan_asset_bonuses" TO "service_role";



GRANT ALL ON TABLE "public"."plan_asset_limits" TO "anon";
GRANT ALL ON TABLE "public"."plan_asset_limits" TO "authenticated";
GRANT ALL ON TABLE "public"."plan_asset_limits" TO "service_role";



GRANT ALL ON TABLE "public"."plan_assets" TO "anon";
GRANT ALL ON TABLE "public"."plan_assets" TO "authenticated";
GRANT ALL ON TABLE "public"."plan_assets" TO "service_role";



GRANT ALL ON TABLE "public"."plan_country_configurations" TO "anon";
GRANT ALL ON TABLE "public"."plan_country_configurations" TO "authenticated";
GRANT ALL ON TABLE "public"."plan_country_configurations" TO "service_role";



GRANT ALL ON TABLE "public"."platform_assignments" TO "anon";
GRANT ALL ON TABLE "public"."platform_assignments" TO "authenticated";
GRANT ALL ON TABLE "public"."platform_assignments" TO "service_role";



GRANT ALL ON TABLE "public"."platform_countries" TO "anon";
GRANT ALL ON TABLE "public"."platform_countries" TO "authenticated";
GRANT ALL ON TABLE "public"."platform_countries" TO "service_role";



GRANT ALL ON TABLE "public"."platforms" TO "anon";
GRANT ALL ON TABLE "public"."platforms" TO "authenticated";
GRANT ALL ON TABLE "public"."platforms" TO "service_role";



GRANT ALL ON TABLE "public"."price_tariffs" TO "anon";
GRANT ALL ON TABLE "public"."price_tariffs" TO "authenticated";
GRANT ALL ON TABLE "public"."price_tariffs" TO "service_role";



GRANT ALL ON TABLE "public"."roles" TO "anon";
GRANT ALL ON TABLE "public"."roles" TO "authenticated";
GRANT ALL ON TABLE "public"."roles" TO "service_role";



GRANT ALL ON TABLE "public"."subscription_assets" TO "anon";
GRANT ALL ON TABLE "public"."subscription_assets" TO "authenticated";
GRANT ALL ON TABLE "public"."subscription_assets" TO "service_role";



GRANT ALL ON TABLE "public"."subscription_items" TO "anon";
GRANT ALL ON TABLE "public"."subscription_items" TO "authenticated";
GRANT ALL ON TABLE "public"."subscription_items" TO "service_role";



GRANT ALL ON TABLE "public"."subscription_plans" TO "anon";
GRANT ALL ON TABLE "public"."subscription_plans" TO "authenticated";
GRANT ALL ON TABLE "public"."subscription_plans" TO "service_role";



GRANT ALL ON TABLE "public"."system_alerts" TO "anon";
GRANT ALL ON TABLE "public"."system_alerts" TO "authenticated";
GRANT ALL ON TABLE "public"."system_alerts" TO "service_role";



GRANT ALL ON TABLE "public"."tariff_asset_prices" TO "anon";
GRANT ALL ON TABLE "public"."tariff_asset_prices" TO "authenticated";
GRANT ALL ON TABLE "public"."tariff_asset_prices" TO "service_role";



GRANT ALL ON TABLE "public"."tenant_integrations" TO "anon";
GRANT ALL ON TABLE "public"."tenant_integrations" TO "authenticated";
GRANT ALL ON TABLE "public"."tenant_integrations" TO "service_role";



GRANT ALL ON TABLE "public"."tenant_settings" TO "anon";
GRANT ALL ON TABLE "public"."tenant_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."tenant_settings" TO "service_role";



GRANT ALL ON TABLE "public"."tenant_subscriptions" TO "anon";
GRANT ALL ON TABLE "public"."tenant_subscriptions" TO "authenticated";
GRANT ALL ON TABLE "public"."tenant_subscriptions" TO "service_role";



GRANT ALL ON TABLE "public"."tenant_template_settings" TO "anon";
GRANT ALL ON TABLE "public"."tenant_template_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."tenant_template_settings" TO "service_role";



GRANT ALL ON TABLE "public"."tenants" TO "anon";
GRANT ALL ON TABLE "public"."tenants" TO "authenticated";
GRANT ALL ON TABLE "public"."tenants" TO "service_role";



GRANT ALL ON TABLE "public"."timezones" TO "anon";
GRANT ALL ON TABLE "public"."timezones" TO "authenticated";
GRANT ALL ON TABLE "public"."timezones" TO "service_role";



GRANT ALL ON TABLE "public"."translations" TO "anon";
GRANT ALL ON TABLE "public"."translations" TO "authenticated";
GRANT ALL ON TABLE "public"."translations" TO "service_role";



GRANT ALL ON TABLE "public"."vendor_platform_commissions" TO "anon";
GRANT ALL ON TABLE "public"."vendor_platform_commissions" TO "authenticated";
GRANT ALL ON TABLE "public"."vendor_platform_commissions" TO "service_role";



GRANT ALL ON TABLE "public"."vendor_tenants" TO "anon";
GRANT ALL ON TABLE "public"."vendor_tenants" TO "authenticated";
GRANT ALL ON TABLE "public"."vendor_tenants" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";































