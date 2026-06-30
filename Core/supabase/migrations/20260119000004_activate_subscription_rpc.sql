
-- Función para activar suscripción y actualizar estado del tenant
CREATE OR REPLACE FUNCTION activate_subscription(p_tenant_id UUID, p_plan_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
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
