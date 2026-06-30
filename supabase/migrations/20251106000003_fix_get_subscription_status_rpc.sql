DROP FUNCTION IF EXISTS public.get_subscription_status_for_tenant(uuid);

CREATE FUNCTION public.get_subscription_status_for_tenant(p_tenant_id uuid)
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
    -- Select specific columns into v_subscription to avoid ambiguity and ensure all fields are present
    SELECT
        ts.active_plan_id,
        ts.status,
        ts.is_trial,
        ts.trial_ends_at,
        ts.start_date,
        ts.end_date
    INTO v_subscription
    FROM public.tenant_subscriptions ts
    WHERE ts.tenant_id = p_tenant_id AND ts.is_active = TRUE
    ORDER BY ts.created_at DESC
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
        NULL::integer,
        NULL::integer,
        NULL::text[];
      RETURN;
    END IF;

    -- Get platform_id for the tenant
    SELECT p.id INTO v_platform_id FROM public.tenants t JOIN public.platforms p ON t.platform_id = p.id WHERE t.id = p_tenant_id;

    -- Get plan_country_configuration_id for the active plan and tenant's country
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
$$ LANGUAGE plpgsql;