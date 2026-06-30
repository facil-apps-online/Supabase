-- Create RPC to get tenant plan limits from Core
-- This function returns the theoretical limits of the plan, not the actual usage.

DROP FUNCTION IF EXISTS public.get_tenant_plan_limits(uuid);

CREATE OR REPLACE FUNCTION public.get_tenant_plan_limits(p_tenant_id uuid)
RETURNS TABLE (
  plan_name text,
  status text,
  is_trial boolean,
  trial_ends_at timestamptz,
  starts_at timestamptz,
  ends_at timestamptz,
  max_users integer,
  max_branches integer,
  plan_features text[]
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_subscription record;
    v_pcc_id uuid;
    v_platform_id uuid;
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

    -- Get platform_id for the tenant from tenants table in Core
    SELECT t.platform_id INTO v_platform_id FROM public.tenants t WHERE t.id = p_tenant_id;

    -- Get limits. Note: 'users_%' and 'suc_%' are patterns. 
    -- We assume specific keys like 'suc_glam', 'suc_tattoo' based on platform.
    -- Using LIKE allows flexibility if we add suffix.
    
    SELECT COALESCE(pal.value::integer, 0) INTO v_max_users
    FROM public.plan_asset_limits pal
    JOIN public.plan_assets pa ON pal.asset_id = pa.id
    WHERE pal.plan_country_config_id = v_pcc_id 
    AND pa.asset_key LIKE 'users_%' 
    AND pa.platform_id = v_platform_id 
    LIMIT 1;

    SELECT COALESCE(pal.value::integer, 0) INTO v_max_branches
    FROM public.plan_asset_limits pal
    JOIN public.plan_assets pa ON pal.asset_id = pa.id
    WHERE pal.plan_country_config_id = v_pcc_id 
    AND pa.asset_key LIKE 'suc_%' 
    AND pa.platform_id = v_platform_id 
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
