-- Migration: Activar el trial real del plan de la plataforma al redimir una invitación de
-- vendedor, en vez de solo vincular vendor_tenants sin ninguna suscripción de por medio.
--
-- No reutilizamos activate_subscription() porque esa función también la invoca
-- wompi-webhook-handler para activaciones de pago reales (siempre pone is_trial = false y no
-- acepta una duración personalizada) — modificarla arriesgaría el flujo de cobros. En su lugar,
-- esta función es específica para el trial: el tope de días SIEMPRE es duration_days del plan
-- is_default_trial de la plataforma (LEAST(...)) — el vendedor solo puede pedir menos días,
-- nunca más, sin importar lo que se le pase.

CREATE OR REPLACE FUNCTION public.activate_vendor_trial_subscription(
    p_tenant_id uuid,
    p_platform_id uuid,
    p_requested_days integer DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_plan_id uuid;
    v_duration_days int;
    v_country_id uuid;
    v_pcc_id uuid;
    v_effective_days int;
    v_new_start_date timestamptz;
    v_new_end_date timestamptz;
BEGIN
    SELECT id, duration_days INTO v_plan_id, v_duration_days
    FROM public.subscription_plans
    WHERE platform_id = p_platform_id AND is_default_trial = true
    LIMIT 1;

    IF v_plan_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'La plataforma no tiene un plan de prueba configurado.');
    END IF;

    SELECT country_id INTO v_country_id FROM public.tenants WHERE id = p_tenant_id;
    IF v_country_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'El tenant no tiene país configurado.');
    END IF;

    SELECT id INTO v_pcc_id
    FROM public.plan_country_configurations
    WHERE plan_id = v_plan_id AND country_id = v_country_id;

    IF v_pcc_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'El plan de prueba no está disponible para el país del tenant.');
    END IF;

    -- Tope duro: nunca más días que el plan, sin importar p_requested_days.
    v_effective_days := LEAST(COALESCE(p_requested_days, v_duration_days), v_duration_days);
    IF v_effective_days < 1 THEN
        v_effective_days := v_duration_days;
    END IF;

    v_new_start_date := now();
    v_new_end_date := v_new_start_date + (v_effective_days || ' days')::interval;

    UPDATE public.tenant_subscriptions SET is_active = false WHERE tenant_id = p_tenant_id;

    INSERT INTO public.tenant_subscriptions (
        tenant_id, platform_id, plan_country_configuration_id, is_active, start_date, end_date, is_trial
    ) VALUES (
        p_tenant_id, p_platform_id, v_pcc_id, true, v_new_start_date, v_new_end_date, true
    );

    UPDATE public.tenants SET subscription_status = 'trial' WHERE id = p_tenant_id;

    RETURN jsonb_build_object('success', true, 'plan_id', v_plan_id, 'days_granted', v_effective_days, 'end_date', v_new_end_date);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

-- El tope de días ahora lo define el plan de cada plataforma, no un ajuste global.
ALTER TABLE public.global_settings DROP COLUMN IF EXISTS max_vendor_trial_days;
