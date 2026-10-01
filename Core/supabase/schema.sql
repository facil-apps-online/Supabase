


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






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgjwt" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE TYPE "public"."client_email_queue_status" AS ENUM (
    'PENDING',
    'SENT',
    'FAILED',
    'PROCESSING'
);


ALTER TYPE "public"."client_email_queue_status" OWNER TO "postgres";


CREATE TYPE "public"."client_whatsapp_queue_status" AS ENUM (
    'PENDING',
    'SENT',
    'FAILED',
    'PROCESSING'
);


ALTER TYPE "public"."client_whatsapp_queue_status" OWNER TO "postgres";


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


CREATE OR REPLACE FUNCTION "public"."activate_subscription"("p_tenant_id" "uuid", "p_plan_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_platform_id UUID;
    v_duration_days INT;
    v_country_id UUID;
    v_pcc_id UUID;
    v_previous_end_date TIMESTAMPTZ;
    v_new_start_date TIMESTAMPTZ;
    v_new_end_date TIMESTAMPTZ;
BEGIN
    -- 1. Obtener datos del plan
    SELECT platform_id, duration_days INTO v_platform_id, v_duration_days
    FROM subscription_plans
    WHERE id = p_plan_id;

    IF v_platform_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Plan no encontrado');
    END IF;

    -- 2. Obtener país del tenant
    SELECT country_id INTO v_country_id
    FROM tenants
    WHERE id = p_tenant_id;

    IF v_country_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Tenant no tiene país configurado');
    END IF;

    -- 3. Buscar configuración del plan para el país (Plan Country Configuration)
    SELECT id INTO v_pcc_id
    FROM plan_country_configurations
    WHERE plan_id = p_plan_id AND country_id = v_country_id;

    IF v_pcc_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Configuración de plan no disponible para el país del tenant');
    END IF;

    -- 4. Calcular fechas (sumar tiempo si ya tiene subscripción activa)
    SELECT end_date INTO v_previous_end_date
    FROM tenant_subscriptions
    WHERE tenant_id = p_tenant_id AND is_active = true
    LIMIT 1;

    v_new_start_date := NOW();

    IF v_previous_end_date IS NOT NULL AND v_previous_end_date > v_new_start_date THEN
        v_new_start_date := v_previous_end_date;
    END IF;

    v_new_end_date := v_new_start_date + (v_duration_days || ' days')::INTERVAL;

    -- 5. Desactivar suscripciones anteriores
    UPDATE tenant_subscriptions
    SET is_active = false
    WHERE tenant_id = p_tenant_id;

    -- 6. Insertar nueva suscripción
    INSERT INTO tenant_subscriptions (
        tenant_id,
        platform_id,
        plan_country_configuration_id,
        is_active,
        start_date,
        end_date,
        is_trial
    ) VALUES (
        p_tenant_id,
        v_platform_id,
        v_pcc_id,
        true,
        v_new_start_date,
        v_new_end_date,
        false
    );

    -- 7. Actualizar estado del tenant
    UPDATE tenants
    SET subscription_status = 'active'
    WHERE id = p_tenant_id;

    RETURN jsonb_build_object('success', true, 'message', 'Suscripción activada correctamente');

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;


ALTER FUNCTION "public"."activate_subscription"("p_tenant_id" "uuid", "p_plan_id" "uuid") OWNER TO "postgres";


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


CREATE OR REPLACE FUNCTION "public"."get_api_health_stats"() RETURNS json
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    -- Clean up old records
    DELETE FROM public.api_request_metrics WHERE created_at < now() - interval '2 months';

    -- Return the statistics
    RETURN (
        WITH metrics_last_hour AS (
            SELECT
                response_time_ms,
                status_code,
                created_at,
                path
            FROM public.api_request_metrics
            WHERE created_at >= now() - interval '60 minutes'
        ),
        metrics_last_month AS (
            SELECT
                response_time_ms,
                path,
                created_at
            FROM public.api_request_metrics
            WHERE created_at >= now() - interval '1 month'
        ),
        rpm_data AS (
            SELECT
                date_trunc('minute', created_at) AS time_bucket,
                count(*) AS request_count
            FROM metrics_last_hour
            GROUP BY time_bucket
            ORDER BY time_bucket
        ),
        high_latency_grouped AS (
            SELECT
                path,
                count(*) as total,
                avg(response_time_ms) as avg_latency,
                max(response_time_ms) as max_latency
            FROM metrics_last_month
            WHERE response_time_ms > 1000
            GROUP BY path
            ORDER BY total DESC
        )
        SELECT json_build_object(
            'avg_latency_ms', (SELECT COALESCE(avg(response_time_ms), 0) FROM metrics_last_hour),
            'error_rate_percentage', (
                SELECT COALESCE(
                    (count(*) FILTER (WHERE status_code >= 500) * 100.0) / NULLIF(count(*), 0),
                    0
                )
                FROM metrics_last_hour
            ),
            'high_latency_requests', (SELECT COALESCE(sum(total), 0) FROM high_latency_grouped),
            'high_latency_list', (SELECT COALESCE(json_agg(high_latency_grouped), '[]'::json) FROM high_latency_grouped),
            'requests_per_minute', (SELECT COALESCE(json_agg(rpm_data), '[]'::json) FROM rpm_data)
        )
    );
END;
$$;


ALTER FUNCTION "public"."get_api_health_stats"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_calculated_plan_prices"("p_platform_id" "uuid") RETURNS TABLE("plan_id" "uuid", "plan_name" "text", "plan_description" "text", "plan_features" "text"[], "billing_frequency_months" integer, "price_id" "uuid", "base_price_cop" numeric, "extra_branch_price_cop" numeric, "country_id" "uuid", "country_name" "text", "calculated_price" numeric, "calculated_extra_branch_price" numeric, "calculated_promotional_price" numeric, "currency_code" "text", "currency_symbol" "text", "is_default_trial" boolean)
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
        SELECT 
            (t.amount_in_cents / 100.0) as amount,
            t.created_at,
            ten.id as tenant_id,
            ten.created_at as tenant_created_at,
            ten.platform_id
        FROM public.transactions t
        JOIN public.tenants ten ON t.tenant_id = ten.id
        JOIN public.platforms p ON ten.platform_id = p.id
        WHERE t.status IN ('APPROVED', 'COMPLETED') 
          AND t.environment <> 'test'
          AND ten.is_system_owner = FALSE
          AND p.status = 'production'
          AND (p_platform_id IS NULL OR ten.platform_id = p_platform_id)
    ),
    monthly_revenue AS (
        SELECT COALESCE(SUM(amount), 0) as total
        FROM valid_payments
        WHERE created_at >= date_trunc('month', NOW() - interval '1 month')
          AND created_at < date_trunc('month', NOW())
    )
    SELECT
        (SELECT total FROM monthly_revenue) AS mrr,
        (SELECT total * 12 FROM monthly_revenue) AS arr,
        (SELECT COALESCE(SUM(amount), 0) FROM valid_payments WHERE created_at >= NOW() - interval '30 days') AS total_revenue_last_30_days,
        (SELECT COUNT(DISTINCT t.id) FROM public.tenants t JOIN public.platforms p ON t.platform_id = p.id WHERE t.created_at >= NOW() - interval '30 days' AND t.is_system_owner = FALSE AND p.status = 'production' AND (p_platform_id IS NULL OR t.platform_id = p_platform_id)) AS new_tenants_last_30_days,
        (SELECT COUNT(*) FROM public.tenant_subscriptions ts JOIN public.tenants t ON ts.tenant_id = t.id JOIN public.platforms p ON t.platform_id = p.id WHERE (ts.end_date IS NULL OR ts.end_date >= NOW()) AND ts.start_date <= NOW() AND t.is_system_owner = FALSE AND p.status = 'production' AND (p_platform_id IS NULL OR t.platform_id = p_platform_id)) AS active_subscriptions,
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
            ten.platform_id,
            SUM(t.amount_in_cents / 100.0) as total
        FROM public.transactions t
        JOIN public.tenants ten ON t.tenant_id = ten.id
        WHERE t.status IN ('APPROVED', 'COMPLETED')
          AND t.environment = 'production'
          AND ten.is_system_owner = FALSE
          AND t.created_at >= date_trunc('month', NOW() - interval '1 month')
          AND t.created_at < date_trunc('month', NOW())
        GROUP BY ten.platform_id
    ),
    active_subs AS (
        SELECT
            ten.platform_id,
            COUNT(*) as total
        FROM public.tenant_subscriptions ts
        JOIN public.tenants ten ON ts.tenant_id = ten.id
        WHERE (ts.end_date IS NULL OR ts.end_date >= NOW())
          AND ts.start_date <= NOW()
          AND ten.is_system_owner = FALSE
        GROUP BY ten.platform_id
    )
    SELECT
        p.id as platform_id,
        p.name as platform_name,
        COALESCE(mr.total, 0) as mrr,
        COALESCE(asub.total, 0) as active_subscriptions
    FROM public.platforms p
    LEFT JOIN monthly_revenue mr ON p.id = mr.platform_id
    LEFT JOIN active_subs asub ON p.id = asub.platform_id
    WHERE p.status = 'production';
END;
$$;


ALTER FUNCTION "public"."get_platforms_stats"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."phone_prefixes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "country_name" "text" NOT NULL,
    "iso_code" character varying(2) NOT NULL,
    "prefix" character varying(10) NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."phone_prefixes" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_public_phone_prefixes"() RETURNS SETOF "public"."phone_prefixes"
    LANGUAGE "sql" SECURITY DEFINER
    AS $$
  SELECT *
  FROM public.phone_prefixes
  ORDER BY country_name ASC;
$$;


ALTER FUNCTION "public"."get_public_phone_prefixes"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_public_registration_data"("p_platform_id" "uuid") RETURNS json
    LANGUAGE "sql" SECURITY DEFINER
    AS $$
  SELECT json_build_object(
    'countries', (
      SELECT json_agg(
        json_build_object(
          'id', c.id,
          'name', c.name,
          'iso_code', c.iso_code,
          'default_localization_id', c.default_localization_id,
          'default_currency_id', c.default_currency_id,
          'timezones', (
            SELECT json_agg(tz.name)
            FROM public.country_timezones ct
            JOIN public.timezones tz ON ct.timezone_id = tz.id
            WHERE ct.country_id = c.id
          )
        )
      )
      FROM countries c
      JOIN platform_countries pc ON c.id = pc.country_id -- Join with linking table
      WHERE c.is_active = true AND pc.platform_id = p_platform_id -- Filter by platform_id
    ),
    'languages', (
      SELECT json_agg(
        json_build_object(
          'id', l.id,
          'name', l.name,
          'iso_code', l.iso_code
        )
      )
      FROM languages l
      WHERE l.is_active = true
    ),
    'currencies', (
      SELECT json_agg(
        json_build_object(
          'id', curr.id,
          'name', curr.name,
          'symbol', curr.symbol,
          'code', curr.code,
          'decimal_places', curr.decimal_places,
          'symbol_position', curr.symbol_position,
          'decimal_separator', curr.decimal_separator,
          'thousands_separator', curr.thousands_separator
        )
      )
      FROM currencies curr
      WHERE curr.is_active = true
    )
  );
$$;


ALTER FUNCTION "public"."get_public_registration_data"("p_platform_id" "uuid") OWNER TO "postgres";


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
            tr.amount_in_cents / 100.0 as amount,
            ten.platform_id,
            tr.tenant_id,
            tr.created_at
        FROM public.transactions tr
        JOIN public.tenants ten ON tr.tenant_id = ten.id
        WHERE tr.status IN ('APPROVED', 'COMPLETED') AND tr.environment = 'production'
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
            tr.amount_in_cents / 100.0 as amount,
            ten.platform_id,
            tr.tenant_id,
            tr.created_at
        FROM public.transactions tr
        JOIN public.tenants ten ON tr.tenant_id = ten.id
        WHERE tr.status IN ('APPROVED', 'COMPLETED') AND tr.environment = 'production'
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


CREATE OR REPLACE FUNCTION "public"."get_tenant_plan_limits"("p_tenant_id" "uuid", "p_platform_id" "uuid") RETURNS TABLE("plan_name" "text", "status" "text", "is_trial" boolean, "trial_ends_at" timestamp with time zone, "starts_at" timestamp with time zone, "ends_at" timestamp with time zone, "max_users" integer, "max_branches" integer, "plan_features" "text"[])
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_subscription record;
    v_pcc_id uuid;
    v_status text;
    v_days_past_due int;
    v_max_users integer;
    v_max_branches integer;
BEGIN
    -- Get the most recent active subscription for the tenant
    SELECT
        ts.plan_country_configuration_id,
        ts.is_active,
        ts.is_trial,
        ts.end_date,
        ts.start_date
    INTO v_subscription
    FROM public.tenant_subscriptions ts
    WHERE ts.tenant_id = p_tenant_id AND ts.is_active = TRUE
    ORDER BY ts.start_date DESC
    LIMIT 1;

    -- If no active subscription, return a 'cancelled' status
    IF NOT FOUND THEN
      RETURN QUERY SELECT
        'Sin Suscripción'::text,
        'cancelado'::text,
        FALSE::boolean,
        NULL::timestamptz,
        NULL::timestamptz,
        NULL::timestamptz,
        0::integer,
        0::integer,
        NULL::text[];
      RETURN;
    END IF;

    -- Determine the status based on the end date
    IF v_subscription.end_date IS NULL OR v_subscription.end_date > now() THEN
        v_status := 'activo';
    ELSE
        v_days_past_due := EXTRACT(DAY FROM now() - v_subscription.end_date);
        IF v_days_past_due > 7 THEN
            v_status := 'suspendido';
        ELSE
            v_status := 'gracia';
        END IF;
    END IF;

    v_pcc_id := v_subscription.plan_country_configuration_id;

    -- Get limits. Note: 'users_%' and 'suc_%' are patterns. 
    -- We assume specific keys like 'suc_glam', 'suc_tattoo' based on platform.
    -- Using LIKE allows flexibility if we add suffix.
    
    SELECT COALESCE(pal.value::integer, 0) INTO v_max_users
    FROM public.plan_asset_limits pal
    JOIN public.plan_assets pa ON pal.asset_id = pa.id
    WHERE pal.plan_country_config_id = v_pcc_id 
    AND pa.asset_key LIKE 'users_%' 
    AND pa.platform_id = p_platform_id 
    LIMIT 1;

    SELECT COALESCE(pal.value::integer, 0) INTO v_max_branches
    FROM public.plan_asset_limits pal
    JOIN public.plan_assets pa ON pal.asset_id = pa.id
    WHERE pal.plan_country_config_id = v_pcc_id 
    AND pa.asset_key LIKE 'suc_%' 
    AND pa.platform_id = p_platform_id 
    LIMIT 1;

    RETURN QUERY
    SELECT
        sp.name AS plan_name,
        v_status AS status,
        v_subscription.is_trial,
        v_subscription.end_date AS trial_ends_at,
        v_subscription.start_date AS starts_at,
        v_subscription.end_date AS ends_at,
        v_max_users AS max_users,
        v_max_branches AS max_branches,
        pcc.features AS plan_features
    FROM public.plan_country_configurations pcc
    JOIN public.subscription_plans sp ON pcc.plan_id = sp.id
    WHERE pcc.id = v_pcc_id;
END;
$$;


ALTER FUNCTION "public"."get_tenant_plan_limits"("p_tenant_id" "uuid", "p_platform_id" "uuid") OWNER TO "postgres";


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


CREATE OR REPLACE FUNCTION "public"."invoke_process_whatsapp_queue"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    PERFORM net.http_post(
        url := 'https://lvdrwumtbhvbtolqgrwi.supabase.co/functions/v1/process-whatsapp-queue',
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imx2ZHJ3dW10Ymh2YnRvbHFncndpIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc2Njg0MjY4NSwiZXhwIjoyMDgyNDE4Njg1fQ.Knh0tXKUT8yd6PmQ4WeJFOXwLwOqREdbsGH4ktgglF0'
        ),
        body := '{}'::jsonb
    );
END;
$$;


ALTER FUNCTION "public"."invoke_process_whatsapp_queue"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_super_admin"() RETURNS boolean
    LANGUAGE "sql" STABLE
    AS $$
  SELECT get_current_role_name() = 'super_admin';
$$;


ALTER FUNCTION "public"."is_super_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."log_api_metric"("p_tenant_id" "uuid", "p_path" "text", "p_method" "text", "p_status_code" integer, "p_response_time_ms" integer) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_platform_id uuid;
BEGIN
    SELECT platform_id INTO v_platform_id FROM public.tenants WHERE id = p_tenant_id;

    IF v_platform_id IS NOT NULL THEN
        INSERT INTO public.api_request_metrics (
            tenant_id, platform_id, path, method, status_code, response_time_ms
        ) VALUES (
            p_tenant_id, v_platform_id, p_path, p_method, p_status_code, p_response_time_ms
        );
    END IF;
END;
$$;


ALTER FUNCTION "public"."log_api_metric"("p_tenant_id" "uuid", "p_path" "text", "p_method" "text", "p_status_code" integer, "p_response_time_ms" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."log_audit_action_core"("p_tenant_id" "uuid", "p_user_id" "uuid", "p_user_name" "text", "p_branch_id" "uuid", "p_action" "text", "p_module" "text", "p_entity_type" "text", "p_entity_id" "uuid", "p_root_entity_type" "text", "p_root_entity_id" "uuid", "p_old_value" "jsonb", "p_new_value" "jsonb", "p_metadata" "jsonb", "p_ip_address" "inet", "p_user_agent" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_platform_id uuid;
BEGIN
    SELECT platform_id INTO v_platform_id FROM public.tenants WHERE id = p_tenant_id;

    IF v_platform_id IS NOT NULL THEN
        INSERT INTO public.audit_logs (
            tenant_id,
            platform_id,
            user_id,
            user_name,
            branch_id,
            action,
            module,
            entity_type,
            entity_id,
            root_entity_type,
            root_entity_id,
            old_value,
            new_value,
            metadata,
            ip_address,
            user_agent
        ) VALUES (
            p_tenant_id,
            v_platform_id,
            p_user_id,
            p_user_name,
            p_branch_id,
            p_action,
            p_module,
            p_entity_type,
            p_entity_id,
            p_root_entity_type,
            p_root_entity_id,
            p_old_value,
            p_new_value,
            p_metadata,
            p_ip_address,
            p_user_agent
        );
    END IF;
END;
$$;


ALTER FUNCTION "public"."log_audit_action_core"("p_tenant_id" "uuid", "p_user_id" "uuid", "p_user_name" "text", "p_branch_id" "uuid", "p_action" "text", "p_module" "text", "p_entity_type" "text", "p_entity_id" "uuid", "p_root_entity_type" "text", "p_root_entity_id" "uuid", "p_old_value" "jsonb", "p_new_value" "jsonb", "p_metadata" "jsonb", "p_ip_address" "inet", "p_user_agent" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."process_branch_activation_billing"("p_tenant_id" "uuid", "p_quantity_to_activate" integer, "p_current_active_count" integer, "p_platform_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_subscription record;
    v_plan_limit integer := 0;
    v_purchased_extras integer := 0;
    v_total_capacity integer := 0;
    v_slots_needed integer;
    v_asset_id uuid;
    v_asset_key text;
    v_tariff_price numeric;
    v_currency_id uuid;
    v_prorated_amount numeric := 0;
    v_days_in_cycle integer;
    v_days_remaining integer;
    v_invoice_id uuid;
    v_invoice_number text;
    v_billing_address text;
    v_contact_email text;
    v_legal_name text;
    v_tax_id text;
    v_usage_tracking_id bigint;
BEGIN
    -- 1. Obtener Suscripción Activa
    SELECT 
        ts.id, 
        ts.start_date, 
        ts.end_date, 
        ts.plan_country_configuration_id,
        pcc.plan_id
    INTO v_subscription
    FROM public.tenant_subscriptions ts
    JOIN public.plan_country_configurations pcc ON ts.plan_country_configuration_id = pcc.id
    WHERE ts.tenant_id = p_tenant_id 
    AND ts.is_active = TRUE
    LIMIT 1;

    IF v_subscription.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'No active subscription found.');
    END IF;

    -- 2. Identificar el Asset
    SELECT id, asset_key INTO v_asset_id, v_asset_key
    FROM public.plan_assets 
    WHERE platform_id = p_platform_id 
    AND asset_key LIKE 'suc_%' 
    LIMIT 1;

    IF v_asset_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Branch asset definition not found for this platform.');
    END IF;

    -- 3. Obtener Límite Base
    SELECT COALESCE(value::integer, 0) INTO v_plan_limit
    FROM public.plan_asset_limits
    WHERE plan_country_config_id = v_subscription.plan_country_configuration_id
    AND asset_id = v_asset_id;

    -- 4. Obtener Extras ya comprados
    SELECT COALESCE(SUM(quantity), 0)::integer INTO v_purchased_extras
    FROM public.subscription_items
    WHERE subscription_id = v_subscription.id
    AND item_id = v_asset_id;

    v_total_capacity := v_plan_limit + v_purchased_extras;
    v_slots_needed := (p_current_active_count + p_quantity_to_activate) - v_total_capacity;

    -- Update Usage Tracking (Logic correction: Check existence first)
    SELECT id INTO v_usage_tracking_id 
    FROM public.asset_usage_tracking 
    WHERE tenant_id = p_tenant_id 
    AND asset_id = v_asset_id 
    AND usage_period_start = v_subscription.start_date;

    IF v_usage_tracking_id IS NOT NULL THEN
        UPDATE public.asset_usage_tracking 
        SET quantity_used = p_current_active_count + p_quantity_to_activate
        WHERE id = v_usage_tracking_id;
    ELSE
        INSERT INTO public.asset_usage_tracking (tenant_id, asset_id, usage_period_start, usage_period_end, quantity_used, platform_id)
        VALUES (p_tenant_id, v_asset_id, v_subscription.start_date, v_subscription.end_date, p_current_active_count + p_quantity_to_activate, p_platform_id);
    END IF;

    -- Si no necesitamos slots extra, autorizamos
    IF v_slots_needed <= 0 THEN
        RETURN jsonb_build_object(
            'success', true, 
            'action', 'allow_free', 
            'message', 'Activation authorized within plan limits.'
        );
    END IF;

    -- 5. Calcular precio para extras
    SELECT tap.extra_unit_price, pt.currency_id
    INTO v_tariff_price, v_currency_id
    FROM public.price_tariffs pt
    JOIN public.tariff_asset_prices tap ON tap.tariff_id = pt.id
    WHERE pt.subscription_plan_id = v_subscription.plan_id
    AND tap.asset_id = v_asset_id
    AND pt.effective_date <= now()
    ORDER BY pt.effective_date DESC
    LIMIT 1;

    IF v_tariff_price IS NULL THEN
        RETURN jsonb_build_object(
            'success', false, 
            'error_code', 'LIMIT_EXCEEDED_NO_UPSELL',
            'message', 'Plan limit reached and no extra branch price defined.'
        );
    END IF;

    -- 6. Calcular Prorrateo
    IF v_subscription.end_date IS NOT NULL AND v_subscription.end_date > now() THEN
        v_days_in_cycle := EXTRACT(DAY FROM (v_subscription.end_date - v_subscription.start_date));
        v_days_remaining := EXTRACT(DAY FROM (v_subscription.end_date - now()));
        
        IF v_days_in_cycle > 0 THEN
            v_prorated_amount := (v_tariff_price / v_days_in_cycle) * v_days_remaining * v_slots_needed;
        ELSE
            v_prorated_amount := v_tariff_price * v_slots_needed;
        END IF;
    ELSE
        v_prorated_amount := v_tariff_price * v_slots_needed;
    END IF;

    v_prorated_amount := ROUND(v_prorated_amount, 2);

    -- 7. Generar Factura
    SELECT billing_address, contact_email, legal_name, tax_id
    INTO v_billing_address, v_contact_email, v_legal_name, v_tax_id
    FROM public.tenants
    WHERE id = p_tenant_id;

    v_invoice_number := 'INV-' || floor(extract(epoch from now())); 

    INSERT INTO public.invoices (
        tenant_id, platform_id, invoice_number, issue_date, due_date, 
        subtotal_amount, total_tax_amount, total_amount, currency_id, status,
        billed_to_tenant_id, contact_email, billing_address
    )
    VALUES (
        p_tenant_id, p_platform_id, v_invoice_number, now(), now(),
        v_prorated_amount, 0, v_prorated_amount, v_currency_id, 'pending',
        p_tenant_id, v_contact_email, v_billing_address
    )
    RETURNING id INTO v_invoice_id;

    INSERT INTO public.invoice_items (
        invoice_id, tenant_id, platform_id, item_type, description, 
        quantity, unit_price, total_price
    )
    VALUES (
        v_invoice_id, p_tenant_id, p_platform_id, 'asset_proration', 
        'Activación Sucursal Adicional (Prorrateo) x' || v_slots_needed,
        v_slots_needed, v_prorated_amount / GREATEST(v_slots_needed, 1), v_prorated_amount
    );

    -- 8. Registrar Subscription Item
    INSERT INTO public.subscription_items (
        subscription_id, item_id, quantity, unit_price_at_addition, platform_id, item_type
    )
    VALUES (
        v_subscription.id, v_asset_id, v_slots_needed, v_tariff_price, p_platform_id, 'extra_branch'
    );

    RETURN jsonb_build_object(
        'success', true,
        'action', 'invoice_generated',
        'invoice_id', v_invoice_id,
        'amount_due', v_prorated_amount,
        'currency_id', v_currency_id,
        'slots_added', v_slots_needed,
        'message', 'Extra branches added. Invoice generated for proration.'
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'message', 'Internal Error in Billing RPC: ' || SQLERRM
    );
END;
$$;


ALTER FUNCTION "public"."process_branch_activation_billing"("p_tenant_id" "uuid", "p_quantity_to_activate" integer, "p_current_active_count" integer, "p_platform_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."queue_client_email"("p_tenant_id" "uuid", "p_recipient_client_id" "uuid", "p_recipient_email" "text", "p_template_type" "text", "p_template_data" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_platform_id uuid;
BEGIN
    SELECT platform_id INTO v_platform_id FROM public.tenants WHERE id = p_tenant_id;

    IF v_platform_id IS NULL THEN
        RAISE WARNING 'Tenant % not found in Core.', p_tenant_id;
        RETURN;
    END IF;

    INSERT INTO public.client_email_queue (
        tenant_id, platform_id, recipient_client_id, recipient_email, template_type, template_data, status
    ) VALUES (
        p_tenant_id, v_platform_id, p_recipient_client_id, p_recipient_email, p_template_type, p_template_data, 'PENDING'
    );
END;
$$;


ALTER FUNCTION "public"."queue_client_email"("p_tenant_id" "uuid", "p_recipient_client_id" "uuid", "p_recipient_email" "text", "p_template_type" "text", "p_template_data" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."queue_client_whatsapp"("p_tenant_id" "uuid", "p_recipient_client_id" "uuid", "p_recipient_phone_number" "text", "p_template_name" "text", "p_template_params" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_platform_id uuid;
BEGIN
    SELECT platform_id INTO v_platform_id FROM public.tenants WHERE id = p_tenant_id;

    IF v_platform_id IS NULL THEN
        RAISE WARNING 'Tenant % not found in Core.', p_tenant_id;
        RETURN;
    END IF;

    INSERT INTO public.client_whatsapp_queue (
        tenant_id, platform_id, recipient_client_id, recipient_phone_number, template_name, template_params, status
    ) VALUES (
        p_tenant_id, v_platform_id, p_recipient_client_id, p_recipient_phone_number, p_template_name, p_template_params, 'PENDING'
    );
END;
$$;


ALTER FUNCTION "public"."queue_client_whatsapp"("p_tenant_id" "uuid", "p_recipient_client_id" "uuid", "p_recipient_phone_number" "text", "p_template_name" "text", "p_template_params" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."queue_password_reset_email"("p_email" "text", "p_token" "text", "p_platform_id" "uuid", "p_tenant_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_reset_link text;
    v_template_data jsonb;
    v_platform_domain text;
BEGIN
    -- 1. Obtener el dominio de la plataforma para construir el enlace
    SELECT domain INTO v_platform_domain FROM public.platforms WHERE id = p_platform_id;
    IF v_platform_domain IS NULL THEN
        -- Como fallback, podríamos usar una URL genérica, pero es mejor que falle para detectar el problema.
        RAISE EXCEPTION 'Platform domain not found for platform_id: %', p_platform_id;
    END IF;

    v_reset_link := 'https://' || v_platform_domain || '/update-password?token=' || p_token;

    -- 2. Preparar el payload para la plantilla
    v_template_data := jsonb_build_object(
        'reset_link', v_reset_link
        -- Aquí se podrían añadir más variables como 'user_name' si se pasara a la RPC
    );

    -- 3. Insertar en la cola de correos, incluyendo el platform_id
    INSERT INTO public.client_email_queue (
        tenant_id,
        platform_id, -- Columna crucial para la selección de plantilla
        recipient_email,
        template_type,
        template_data,
        status
    ) VALUES (
        p_tenant_id,
        p_platform_id,
        p_email,
        'password_reset', -- Tipo de plantilla estándar para esta acción
        v_template_data,
        'PENDING'
    );

    RETURN jsonb_build_object('success', true, 'message', 'Correo de reseteo de contraseña encolado correctamente.');

EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING '[queue_password_reset_email] - Error: %', SQLERRM;
        RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;


ALTER FUNCTION "public"."queue_password_reset_email"("p_email" "text", "p_token" "text", "p_platform_id" "uuid", "p_tenant_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tg_set_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."tg_set_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."upsert_tenant_integration"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_provider_slug" "text", "p_encrypted_credentials" "text", "p_nonce" "text", "p_environment" "text", "p_user_role" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    -- Validation
    IF p_environment NOT IN ('test', 'production') THEN
        RAISE EXCEPTION 'Invalid environment. Must be ''test'' or ''production''.';
    END IF;

    -- Upsert logic
    INSERT INTO public.tenant_integrations (
        tenant_id,
        platform_id, -- Insert platform_id
        provider,
        encrypted_credentials,
        nonce,
        environment,
        is_active,
        updated_at,
        created_at
    )
    VALUES (
        p_tenant_id,
        p_platform_id,
        p_provider_slug,
        p_encrypted_credentials,
        p_nonce,
        p_environment,
        true,
        NOW(),
        NOW()
    )
    ON CONFLICT (tenant_id, provider, environment)
    DO UPDATE SET
        encrypted_credentials = EXCLUDED.encrypted_credentials,
        nonce = EXCLUDED.nonce,
        is_active = TRUE,
        updated_at = NOW();
        -- We don't typically update platform_id on conflict as it shouldn't change for a tenant
END;
$$;


ALTER FUNCTION "public"."upsert_tenant_integration"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_provider_slug" "text", "p_encrypted_credentials" "text", "p_nonce" "text", "p_environment" "text", "p_user_role" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."api_request_metrics" (
    "id" bigint NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "platform_id" "uuid" NOT NULL,
    "path" "text",
    "method" "text",
    "status_code" integer,
    "response_time_ms" integer,
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL
);


ALTER TABLE "public"."api_request_metrics" OWNER TO "postgres";


ALTER TABLE "public"."api_request_metrics" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."api_request_metrics_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



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



CREATE TABLE IF NOT EXISTS "public"."audit_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid",
    "tenant_id" "uuid" NOT NULL,
    "platform_id" "uuid" NOT NULL,
    "branch_id" "uuid",
    "action" "text" NOT NULL,
    "entity_type" "text",
    "entity_id" "uuid",
    "object_type" "text",
    "object_id" "uuid",
    "old_value" "jsonb",
    "new_value" "jsonb",
    "metadata" "jsonb",
    "ip_address" "inet",
    "user_agent" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "module" "text",
    "root_entity_id" "uuid",
    "root_entity_type" "text",
    "user_name" "text"
);


ALTER TABLE "public"."audit_logs" OWNER TO "postgres";


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


CREATE TABLE IF NOT EXISTS "public"."client_email_queue" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "platform_id" "uuid",
    "recipient_client_id" "uuid",
    "recipient_email" "text" NOT NULL,
    "template_type" "text" NOT NULL,
    "template_data" "jsonb",
    "status" "public"."client_email_queue_status" DEFAULT 'PENDING'::"public"."client_email_queue_status" NOT NULL,
    "attempts" integer DEFAULT 0 NOT NULL,
    "last_attempt_at" timestamp with time zone,
    "error_message" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."client_email_queue" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."client_whatsapp_queue" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "platform_id" "uuid",
    "recipient_client_id" "uuid",
    "recipient_phone_number" "text" NOT NULL,
    "template_name" "text" NOT NULL,
    "template_params" "jsonb",
    "status" "public"."client_whatsapp_queue_status" DEFAULT 'PENDING'::"public"."client_whatsapp_queue_status" NOT NULL,
    "attempts" integer DEFAULT 0 NOT NULL,
    "last_attempt_at" timestamp with time zone,
    "error_message" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."client_whatsapp_queue" OWNER TO "postgres";


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


CREATE TABLE IF NOT EXISTS "public"."infrastructure_nodes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "node_name" "text" NOT NULL,
    "description" "text",
    "project_url" "text" NOT NULL,
    "service_role_key" "text" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."infrastructure_nodes" OWNER TO "postgres";


COMMENT ON TABLE "public"."infrastructure_nodes" IS 'Registro de instancias de bases de datos Supabase donde viven las plataformas y tenants.';



COMMENT ON COLUMN "public"."infrastructure_nodes"."service_role_key" IS 'Llave maestra para la comunicación segura entre bases desde las Edge Functions de Core.';



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


CREATE TABLE IF NOT EXISTS "public"."platform_categories" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "slug" "text" NOT NULL,
    "display_order" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."platform_categories" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."platform_category_translations" (
    "category_id" "uuid" NOT NULL,
    "locale" "text" NOT NULL,
    "name" "text" NOT NULL
);


ALTER TABLE "public"."platform_category_translations" OWNER TO "postgres";


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
    "default_language_id" "uuid",
    "slug" "text" NOT NULL,
    "status" "text" DEFAULT 'production'::"text" NOT NULL,
    "logo_url" "text",
    "description_en" "text",
    "social_facebook" "text",
    "social_instagram" "text",
    "display_order" integer DEFAULT 0 NOT NULL,
    "is_public" boolean DEFAULT true NOT NULL,
    "category_id" "uuid",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "infrastructure_node_id" "uuid",
    CONSTRAINT "platforms_status_check" CHECK (("status" = ANY (ARRAY['production'::"text", 'development'::"text", 'planning'::"text"])))
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


CREATE TABLE IF NOT EXISTS "public"."transactions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "platform_id" "uuid" NOT NULL,
    "status" "text" DEFAULT 'PENDING'::"text" NOT NULL,
    "amount_in_cents" bigint NOT NULL,
    "currency" character varying(3) NOT NULL,
    "reference" "text" NOT NULL,
    "provider" "text",
    "provider_transaction_id" "text",
    "payment_method_type" "text",
    "environment" "text" DEFAULT 'production'::"text" NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "line_items" "jsonb" DEFAULT '[]'::"jsonb",
    "actions_snapshot" "jsonb" DEFAULT '[]'::"jsonb",
    "full_response" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "processed_at" timestamp with time zone,
    CONSTRAINT "transactions_environment_check" CHECK (("environment" = ANY (ARRAY['test'::"text", 'production'::"text"])))
);


ALTER TABLE "public"."transactions" OWNER TO "postgres";


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



ALTER TABLE ONLY "public"."api_request_metrics"
    ADD CONSTRAINT "api_request_metrics_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."asset_purposes"
    ADD CONSTRAINT "asset_purposes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."asset_purposes"
    ADD CONSTRAINT "asset_purposes_purpose_key_unique" UNIQUE ("purpose_key");



ALTER TABLE ONLY "public"."asset_usage_tracking"
    ADD CONSTRAINT "asset_usage_tracking_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."asset_usage_tracking"
    ADD CONSTRAINT "asset_usage_tracking_tenant_asset_period_unique" UNIQUE ("tenant_id", "asset_id", "usage_period_start");



ALTER TABLE ONLY "public"."audit_logs"
    ADD CONSTRAINT "audit_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."billing_entities"
    ADD CONSTRAINT "billing_entities_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."client_email_queue"
    ADD CONSTRAINT "client_email_queue_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."client_whatsapp_queue"
    ADD CONSTRAINT "client_whatsapp_queue_pkey" PRIMARY KEY ("id");



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



ALTER TABLE ONLY "public"."infrastructure_nodes"
    ADD CONSTRAINT "infrastructure_nodes_name_key" UNIQUE ("node_name");



ALTER TABLE ONLY "public"."infrastructure_nodes"
    ADD CONSTRAINT "infrastructure_nodes_pkey" PRIMARY KEY ("id");



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



ALTER TABLE ONLY "public"."platform_categories"
    ADD CONSTRAINT "platform_categories_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."platform_categories"
    ADD CONSTRAINT "platform_categories_slug_key" UNIQUE ("slug");



ALTER TABLE ONLY "public"."platform_category_translations"
    ADD CONSTRAINT "platform_category_translations_pkey" PRIMARY KEY ("category_id", "locale");



ALTER TABLE ONLY "public"."platform_countries"
    ADD CONSTRAINT "platform_countries_pkey" PRIMARY KEY ("platform_id", "country_id");



ALTER TABLE ONLY "public"."platforms"
    ADD CONSTRAINT "platforms_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."platforms"
    ADD CONSTRAINT "platforms_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."platforms"
    ADD CONSTRAINT "platforms_slug_key" UNIQUE ("slug");



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



ALTER TABLE ONLY "public"."transactions"
    ADD CONSTRAINT "transactions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."transactions"
    ADD CONSTRAINT "transactions_reference_key" UNIQUE ("reference");



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



CREATE INDEX "idx_api_metrics_created_at" ON "public"."api_request_metrics" USING "btree" ("created_at");



CREATE INDEX "idx_audit_logs_module" ON "public"."audit_logs" USING "btree" ("tenant_id", "module");



CREATE INDEX "idx_audit_logs_root_entity" ON "public"."audit_logs" USING "btree" ("tenant_id", "root_entity_type", "root_entity_id");



CREATE INDEX "idx_audit_logs_tenant" ON "public"."audit_logs" USING "btree" ("tenant_id");



CREATE INDEX "idx_email_queue_status" ON "public"."client_email_queue" USING "btree" ("status");



CREATE INDEX "idx_plan_assets_platform_id" ON "public"."plan_assets" USING "btree" ("platform_id");



CREATE INDEX "idx_platforms_category" ON "public"."platforms" USING "btree" ("category_id");



CREATE INDEX "idx_platforms_infrastructure_node" ON "public"."platforms" USING "btree" ("infrastructure_node_id");



CREATE INDEX "idx_platforms_public_listing" ON "public"."platforms" USING "btree" ("is_public", "display_order", "name") WHERE ("is_public" = true);



CREATE INDEX "idx_price_tariffs_plan_id_effective_date" ON "public"."price_tariffs" USING "btree" ("subscription_plan_id", "effective_date" DESC);



CREATE INDEX "idx_subscription_plans_platform_id" ON "public"."subscription_plans" USING "btree" ("platform_id");



CREATE INDEX "idx_tariff_asset_prices_tariff_id" ON "public"."tariff_asset_prices" USING "btree" ("tariff_id");



CREATE INDEX "idx_tenants_country_id" ON "public"."tenants" USING "btree" ("country_id");



CREATE INDEX "idx_transactions_created_at" ON "public"."transactions" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_transactions_platform_id" ON "public"."transactions" USING "btree" ("platform_id");



CREATE INDEX "idx_transactions_reference" ON "public"."transactions" USING "btree" ("reference");



CREATE INDEX "idx_transactions_status" ON "public"."transactions" USING "btree" ("status");



CREATE INDEX "idx_transactions_tenant_id" ON "public"."transactions" USING "btree" ("tenant_id");



CREATE INDEX "idx_translations_context" ON "public"."translations" USING "btree" ("context");



CREATE INDEX "idx_translations_language_key" ON "public"."translations" USING "btree" ("language_id", "key");



CREATE INDEX "idx_whatsapp_queue_status" ON "public"."client_whatsapp_queue" USING "btree" ("status");



CREATE UNIQUE INDEX "one_billing_entity_idx" ON "public"."billing_entities" USING "btree" ((1));



CREATE UNIQUE INDEX "one_default_trial_per_platform_idx" ON "public"."subscription_plans" USING "btree" ("platform_id") WHERE ("is_default_trial" = true);



CREATE UNIQUE INDEX "roles_name_global_unique_idx" ON "public"."roles" USING "btree" ("name") WHERE (("platform_id" IS NULL) AND ("tenant_id" IS NULL));



CREATE UNIQUE INDEX "roles_name_platform_unique_idx" ON "public"."roles" USING "btree" ("name", "platform_id") WHERE ("tenant_id" IS NULL);



CREATE UNIQUE INDEX "roles_name_tenant_unique_idx" ON "public"."roles" USING "btree" ("name", "tenant_id") WHERE ("tenant_id" IS NOT NULL);



CREATE UNIQUE INDEX "unique_active_integration_per_provider" ON "public"."tenant_integrations" USING "btree" ("tenant_id", "provider") WHERE ("is_active" = true);



CREATE UNIQUE INDEX "unique_owner_per_platform" ON "public"."tenants" USING "btree" ("platform_id") WHERE ("is_system_owner" = true);



CREATE OR REPLACE TRIGGER "trg_infrastructure_nodes_updated_at" BEFORE UPDATE ON "public"."infrastructure_nodes" FOR EACH ROW EXECUTE FUNCTION "public"."tg_set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_platforms_updated_at" BEFORE UPDATE ON "public"."platforms" FOR EACH ROW EXECUTE FUNCTION "public"."tg_set_updated_at"();



CREATE OR REPLACE TRIGGER "update_transactions_moddatetime" BEFORE UPDATE ON "public"."transactions" FOR EACH ROW EXECUTE FUNCTION "public"."moddatetime"('updated_at');



ALTER TABLE ONLY "public"."api_request_metrics"
    ADD CONSTRAINT "api_request_metrics_platform_id_fkey" FOREIGN KEY ("platform_id") REFERENCES "public"."platforms"("id");



ALTER TABLE ONLY "public"."api_request_metrics"
    ADD CONSTRAINT "api_request_metrics_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."asset_usage_tracking"
    ADD CONSTRAINT "asset_usage_tracking_asset_id_fkey" FOREIGN KEY ("asset_id") REFERENCES "public"."plan_assets"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."asset_usage_tracking"
    ADD CONSTRAINT "asset_usage_tracking_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."audit_logs"
    ADD CONSTRAINT "audit_logs_platform_id_fkey" FOREIGN KEY ("platform_id") REFERENCES "public"."platforms"("id");



ALTER TABLE ONLY "public"."audit_logs"
    ADD CONSTRAINT "audit_logs_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."billing_entities"
    ADD CONSTRAINT "billing_entities_billing_country_id_fkey" FOREIGN KEY ("billing_country_id") REFERENCES "public"."countries"("id");



ALTER TABLE ONLY "public"."client_email_queue"
    ADD CONSTRAINT "client_email_queue_platform_id_fkey" FOREIGN KEY ("platform_id") REFERENCES "public"."platforms"("id");



ALTER TABLE ONLY "public"."client_email_queue"
    ADD CONSTRAINT "client_email_queue_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."client_whatsapp_queue"
    ADD CONSTRAINT "client_whatsapp_queue_platform_id_fkey" FOREIGN KEY ("platform_id") REFERENCES "public"."platforms"("id");



ALTER TABLE ONLY "public"."client_whatsapp_queue"
    ADD CONSTRAINT "client_whatsapp_queue_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



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



ALTER TABLE ONLY "public"."platform_category_translations"
    ADD CONSTRAINT "platform_category_translations_category_id_fkey" FOREIGN KEY ("category_id") REFERENCES "public"."platform_categories"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."platform_countries"
    ADD CONSTRAINT "platform_countries_country_id_fkey" FOREIGN KEY ("country_id") REFERENCES "public"."countries"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."platform_countries"
    ADD CONSTRAINT "platform_countries_platform_id_fkey" FOREIGN KEY ("platform_id") REFERENCES "public"."platforms"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."platforms"
    ADD CONSTRAINT "platforms_category_id_fkey" FOREIGN KEY ("category_id") REFERENCES "public"."platform_categories"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."platforms"
    ADD CONSTRAINT "platforms_default_currency_id_fkey" FOREIGN KEY ("default_currency_id") REFERENCES "public"."currencies"("id");



ALTER TABLE ONLY "public"."platforms"
    ADD CONSTRAINT "platforms_default_language_id_fkey" FOREIGN KEY ("default_language_id") REFERENCES "public"."languages"("id");



ALTER TABLE ONLY "public"."platforms"
    ADD CONSTRAINT "platforms_infrastructure_node_id_fkey" FOREIGN KEY ("infrastructure_node_id") REFERENCES "public"."infrastructure_nodes"("id") ON DELETE SET NULL;



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



ALTER TABLE ONLY "public"."transactions"
    ADD CONSTRAINT "transactions_platform_id_fkey" FOREIGN KEY ("platform_id") REFERENCES "public"."platforms"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."transactions"
    ADD CONSTRAINT "transactions_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE SET NULL;



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



ALTER TABLE "public"."api_request_metrics" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."asset_purposes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."asset_usage_tracking" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."audit_logs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."billing_entities" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."client_email_queue" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."client_whatsapp_queue" ENABLE ROW LEVEL SECURITY;


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











































































































































































GRANT ALL ON FUNCTION "public"."activate_subscription"("p_tenant_id" "uuid", "p_plan_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."activate_subscription"("p_tenant_id" "uuid", "p_plan_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."activate_subscription"("p_tenant_id" "uuid", "p_plan_id" "uuid") TO "service_role";



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



GRANT ALL ON FUNCTION "public"."get_api_health_stats"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_api_health_stats"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_api_health_stats"() TO "service_role";



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



GRANT ALL ON TABLE "public"."phone_prefixes" TO "anon";
GRANT ALL ON TABLE "public"."phone_prefixes" TO "authenticated";
GRANT ALL ON TABLE "public"."phone_prefixes" TO "service_role";



GRANT ALL ON FUNCTION "public"."get_public_phone_prefixes"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_public_phone_prefixes"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_public_phone_prefixes"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_public_registration_data"("p_platform_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_public_registration_data"("p_platform_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_public_registration_data"("p_platform_id" "uuid") TO "service_role";



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



GRANT ALL ON FUNCTION "public"."get_tenant_plan_limits"("p_tenant_id" "uuid", "p_platform_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_tenant_plan_limits"("p_tenant_id" "uuid", "p_platform_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_tenant_plan_limits"("p_tenant_id" "uuid", "p_platform_id" "uuid") TO "service_role";



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



GRANT ALL ON FUNCTION "public"."invoke_process_whatsapp_queue"() TO "anon";
GRANT ALL ON FUNCTION "public"."invoke_process_whatsapp_queue"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."invoke_process_whatsapp_queue"() TO "service_role";



GRANT ALL ON FUNCTION "public"."is_super_admin"() TO "anon";
GRANT ALL ON FUNCTION "public"."is_super_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_super_admin"() TO "service_role";



GRANT ALL ON FUNCTION "public"."log_api_metric"("p_tenant_id" "uuid", "p_path" "text", "p_method" "text", "p_status_code" integer, "p_response_time_ms" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."log_api_metric"("p_tenant_id" "uuid", "p_path" "text", "p_method" "text", "p_status_code" integer, "p_response_time_ms" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."log_api_metric"("p_tenant_id" "uuid", "p_path" "text", "p_method" "text", "p_status_code" integer, "p_response_time_ms" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."log_audit_action_core"("p_tenant_id" "uuid", "p_user_id" "uuid", "p_user_name" "text", "p_branch_id" "uuid", "p_action" "text", "p_module" "text", "p_entity_type" "text", "p_entity_id" "uuid", "p_root_entity_type" "text", "p_root_entity_id" "uuid", "p_old_value" "jsonb", "p_new_value" "jsonb", "p_metadata" "jsonb", "p_ip_address" "inet", "p_user_agent" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."log_audit_action_core"("p_tenant_id" "uuid", "p_user_id" "uuid", "p_user_name" "text", "p_branch_id" "uuid", "p_action" "text", "p_module" "text", "p_entity_type" "text", "p_entity_id" "uuid", "p_root_entity_type" "text", "p_root_entity_id" "uuid", "p_old_value" "jsonb", "p_new_value" "jsonb", "p_metadata" "jsonb", "p_ip_address" "inet", "p_user_agent" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."log_audit_action_core"("p_tenant_id" "uuid", "p_user_id" "uuid", "p_user_name" "text", "p_branch_id" "uuid", "p_action" "text", "p_module" "text", "p_entity_type" "text", "p_entity_id" "uuid", "p_root_entity_type" "text", "p_root_entity_id" "uuid", "p_old_value" "jsonb", "p_new_value" "jsonb", "p_metadata" "jsonb", "p_ip_address" "inet", "p_user_agent" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."moddatetime"() TO "postgres";
GRANT ALL ON FUNCTION "public"."moddatetime"() TO "anon";
GRANT ALL ON FUNCTION "public"."moddatetime"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."moddatetime"() TO "service_role";



GRANT ALL ON FUNCTION "public"."oid_dist"("oid", "oid") TO "postgres";
GRANT ALL ON FUNCTION "public"."oid_dist"("oid", "oid") TO "anon";
GRANT ALL ON FUNCTION "public"."oid_dist"("oid", "oid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."oid_dist"("oid", "oid") TO "service_role";



GRANT ALL ON FUNCTION "public"."process_branch_activation_billing"("p_tenant_id" "uuid", "p_quantity_to_activate" integer, "p_current_active_count" integer, "p_platform_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."process_branch_activation_billing"("p_tenant_id" "uuid", "p_quantity_to_activate" integer, "p_current_active_count" integer, "p_platform_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."process_branch_activation_billing"("p_tenant_id" "uuid", "p_quantity_to_activate" integer, "p_current_active_count" integer, "p_platform_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."queue_client_email"("p_tenant_id" "uuid", "p_recipient_client_id" "uuid", "p_recipient_email" "text", "p_template_type" "text", "p_template_data" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."queue_client_email"("p_tenant_id" "uuid", "p_recipient_client_id" "uuid", "p_recipient_email" "text", "p_template_type" "text", "p_template_data" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."queue_client_email"("p_tenant_id" "uuid", "p_recipient_client_id" "uuid", "p_recipient_email" "text", "p_template_type" "text", "p_template_data" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."queue_client_whatsapp"("p_tenant_id" "uuid", "p_recipient_client_id" "uuid", "p_recipient_phone_number" "text", "p_template_name" "text", "p_template_params" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."queue_client_whatsapp"("p_tenant_id" "uuid", "p_recipient_client_id" "uuid", "p_recipient_phone_number" "text", "p_template_name" "text", "p_template_params" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."queue_client_whatsapp"("p_tenant_id" "uuid", "p_recipient_client_id" "uuid", "p_recipient_phone_number" "text", "p_template_name" "text", "p_template_params" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."queue_password_reset_email"("p_email" "text", "p_token" "text", "p_platform_id" "uuid", "p_tenant_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."queue_password_reset_email"("p_email" "text", "p_token" "text", "p_platform_id" "uuid", "p_tenant_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."queue_password_reset_email"("p_email" "text", "p_token" "text", "p_platform_id" "uuid", "p_tenant_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."sign"("payload" json, "secret" "text", "algorithm" "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."sign"("payload" json, "secret" "text", "algorithm" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."sign"("payload" json, "secret" "text", "algorithm" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sign"("payload" json, "secret" "text", "algorithm" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."text_to_bytea"("data" "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."text_to_bytea"("data" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."text_to_bytea"("data" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."text_to_bytea"("data" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."tg_set_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."tg_set_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."tg_set_updated_at"() TO "service_role";



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



GRANT ALL ON FUNCTION "public"."upsert_tenant_integration"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_provider_slug" "text", "p_encrypted_credentials" "text", "p_nonce" "text", "p_environment" "text", "p_user_role" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."upsert_tenant_integration"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_provider_slug" "text", "p_encrypted_credentials" "text", "p_nonce" "text", "p_environment" "text", "p_user_role" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."upsert_tenant_integration"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_provider_slug" "text", "p_encrypted_credentials" "text", "p_nonce" "text", "p_environment" "text", "p_user_role" "text") TO "service_role";



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
























GRANT ALL ON TABLE "public"."api_request_metrics" TO "anon";
GRANT ALL ON TABLE "public"."api_request_metrics" TO "authenticated";
GRANT ALL ON TABLE "public"."api_request_metrics" TO "service_role";



GRANT ALL ON SEQUENCE "public"."api_request_metrics_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."api_request_metrics_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."api_request_metrics_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."asset_purposes" TO "anon";
GRANT ALL ON TABLE "public"."asset_purposes" TO "authenticated";
GRANT ALL ON TABLE "public"."asset_purposes" TO "service_role";



GRANT ALL ON TABLE "public"."asset_usage_tracking" TO "anon";
GRANT ALL ON TABLE "public"."asset_usage_tracking" TO "authenticated";
GRANT ALL ON TABLE "public"."asset_usage_tracking" TO "service_role";



GRANT ALL ON SEQUENCE "public"."asset_usage_tracking_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."asset_usage_tracking_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."asset_usage_tracking_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."audit_logs" TO "anon";
GRANT ALL ON TABLE "public"."audit_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."audit_logs" TO "service_role";



GRANT ALL ON TABLE "public"."billing_entities" TO "anon";
GRANT ALL ON TABLE "public"."billing_entities" TO "authenticated";
GRANT ALL ON TABLE "public"."billing_entities" TO "service_role";



GRANT ALL ON TABLE "public"."client_email_queue" TO "anon";
GRANT ALL ON TABLE "public"."client_email_queue" TO "authenticated";
GRANT ALL ON TABLE "public"."client_email_queue" TO "service_role";



GRANT ALL ON TABLE "public"."client_whatsapp_queue" TO "anon";
GRANT ALL ON TABLE "public"."client_whatsapp_queue" TO "authenticated";
GRANT ALL ON TABLE "public"."client_whatsapp_queue" TO "service_role";



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



GRANT ALL ON TABLE "public"."infrastructure_nodes" TO "anon";
GRANT ALL ON TABLE "public"."infrastructure_nodes" TO "authenticated";
GRANT ALL ON TABLE "public"."infrastructure_nodes" TO "service_role";



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



GRANT ALL ON TABLE "public"."platform_categories" TO "anon";
GRANT ALL ON TABLE "public"."platform_categories" TO "authenticated";
GRANT ALL ON TABLE "public"."platform_categories" TO "service_role";



GRANT ALL ON TABLE "public"."platform_category_translations" TO "anon";
GRANT ALL ON TABLE "public"."platform_category_translations" TO "authenticated";
GRANT ALL ON TABLE "public"."platform_category_translations" TO "service_role";



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



GRANT ALL ON TABLE "public"."transactions" TO "anon";
GRANT ALL ON TABLE "public"."transactions" TO "authenticated";
GRANT ALL ON TABLE "public"."transactions" TO "service_role";



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































