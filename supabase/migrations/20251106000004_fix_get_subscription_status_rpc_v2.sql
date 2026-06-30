DROP FUNCTION IF EXISTS public.get_subscription_status_for_tenant(uuid);

CREATE OR REPLACE FUNCTION public.get_subscription_status_for_tenant(p_tenant_id uuid)
RETURNS TABLE (
  plan_name text,
  status text,
  is_trial boolean,
  trial_ends_at timestamptz,
  starts_at timestamptz,
  ends_at timestamptz,
  max_users integer,
  max_branches integer,
  current_users integer,
  current_branches integer,
  plan_features text[]
)
AS $$
DECLARE
    v_subscription record;
    v_pcc_id uuid;
    v_platform_id uuid;
BEGIN
    -- Select specific columns into v_subscription to use the correct column names
    SELECT
        ts.plan_country_configuration_id,
        ts.is_active,
        ts.is_trial,
        ts.end_date,
        ts.start_date
    INTO v_subscription
    FROM public.tenant_subscriptions ts
    WHERE ts.tenant_id = p_tenant_id AND ts.is_active = TRUE
    ORDER BY ts.start_date DESC -- Order by start_date to get the most recent active plan
    LIMIT 1;

    -- If no active subscription, return a default status
    IF NOT FOUND THEN
      RETURN QUERY SELECT
        'Sin Suscripción'::text,
        'inactive'::text,
        FALSE::boolean,
        NULL::timestamptz,
        NULL::timestamptz,
        NULL::timestamptz,
        NULL::integer,
        NULL::integer,
        (SELECT COUNT(*) FROM public.user_assignments ua WHERE ua.tenant_id = p_tenant_id)::integer,
        (SELECT COUNT(*) FROM public.branches b WHERE b.tenant_id = p_tenant_id)::integer,
        NULL::text[];
      RETURN;
    END IF;

    v_pcc_id := v_subscription.plan_country_configuration_id;

    -- Get platform_id for the tenant
    SELECT t.platform_id INTO v_platform_id FROM public.tenants t WHERE t.id = p_tenant_id;

    RETURN QUERY
    SELECT
        sp.name AS plan_name,
        (CASE WHEN v_subscription.is_active THEN 'active' ELSE 'inactive' END)::text AS status,
        v_subscription.is_trial,
        v_subscription.end_date AS trial_ends_at,
        v_subscription.start_date AS starts_at,
        v_subscription.end_date AS ends_at,
        (SELECT pal.value FROM public.plan_asset_limits pal WHERE pal.plan_country_config_id = v_pcc_id AND pal.asset_id = (SELECT id FROM public.plan_assets WHERE asset_key LIKE 'users_%' AND platform_id = v_platform_id LIMIT 1))::integer AS max_users,
        (SELECT pal.value FROM public.plan_asset_limits pal WHERE pal.plan_country_config_id = v_pcc_id AND pal.asset_id = (SELECT id FROM public.plan_assets WHERE asset_key LIKE 'suc_%' AND platform_id = v_platform_id LIMIT 1))::integer AS max_branches,
        (SELECT COUNT(*) FROM public.user_assignments ua WHERE ua.tenant_id = p_tenant_id)::integer AS current_users,
        (SELECT COUNT(*) FROM public.branches b WHERE b.tenant_id = p_tenant_id)::integer AS current_branches,
        pcc.features AS plan_features
    FROM public.plan_country_configurations pcc
    JOIN public.subscription_plans sp ON pcc.plan_id = sp.id
    WHERE pcc.id = v_pcc_id;
END;
$$ LANGUAGE plpgsql;