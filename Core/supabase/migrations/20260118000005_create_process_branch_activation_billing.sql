-- RPC para procesar la facturación y validación de activación de sucursales
-- Maneja lógica de límites, prorrateo y generación de facturas.

DROP FUNCTION IF EXISTS public.process_branch_activation_billing(uuid, integer, integer, uuid);

CREATE OR REPLACE FUNCTION public.process_branch_activation_billing(
    p_tenant_id uuid,
    p_quantity_to_activate integer,
    p_current_active_count integer,
    p_platform_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
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
BEGIN
    -- 1. Obtener Suscripción Activa y Configuración del País
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

    -- 2. Identificar el Asset "Sucursal" para esta plataforma
    -- Buscamos dinámicamente el asset que empieza con 'suc_' para la plataforma dada
    SELECT id, asset_key INTO v_asset_id, v_asset_key
    FROM public.plan_assets 
    WHERE platform_id = p_platform_id 
    AND asset_key LIKE 'suc_%' 
    LIMIT 1;

    IF v_asset_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Branch asset definition not found for this platform.');
    END IF;

    -- 3. Obtener Límite Base del Plan (Plan Asset Limits)
    SELECT COALESCE(value::integer, 0) INTO v_plan_limit
    FROM public.plan_asset_limits
    WHERE plan_country_config_id = v_subscription.plan_country_configuration_id
    AND asset_id = v_asset_id;

    -- 4. Obtener Extras ya comprados (Subscription Items)
    -- Asumimos que 'subscription_items' rastrea los paquetes adicionales recurrentes
    SELECT COALESCE(SUM(quantity), 0)::integer INTO v_purchased_extras
    FROM public.subscription_items
    WHERE subscription_id = v_subscription.id
    AND item_id = v_asset_id; -- Asumiendo que item_id apunta a plan_assets o hay un mapeo

    -- Capacidad Total Actual = Base + Extras Comprados
    v_total_capacity := v_plan_limit + v_purchased_extras;

    -- Calcular cuántos slots nuevos necesitamos pagar
    -- Uso Final Deseado = Activos Actuales + A Activar
    -- Slots Faltantes = Uso Final Deseado - Capacidad Total
    v_slots_needed := (p_current_active_count + p_quantity_to_activate) - v_total_capacity;

    -- Si no necesitamos slots extra, autorizamos inmediatamente (GRATIS/INCLUIDO)
    IF v_slots_needed <= 0 THEN
        -- Actualizar tracking de uso (informativo)
        INSERT INTO public.asset_usage_tracking (tenant_id, asset_id, usage_period_start, usage_period_end, quantity_used, platform_id)
        VALUES (p_tenant_id, v_asset_id, v_subscription.start_date, v_subscription.end_date, p_current_active_count + p_quantity_to_activate, p_platform_id)
        ON CONFLICT (id) DO UPDATE SET quantity_used = EXCLUDED.quantity_used; -- Nota: Ajustar conflicto real si existe restricción única

        RETURN jsonb_build_object(
            'success', true, 
            'action', 'allow_free', 
            'message', 'Activation authorized within plan limits.'
        );
    END IF;

    -- 5. Si necesitamos slots extra, calcular precio
    -- Obtener la tarifa activa asociada al plan
    SELECT tap.extra_unit_price, pt.currency_id
    INTO v_tariff_price, v_currency_id
    FROM public.price_tariffs pt
    JOIN public.tariff_asset_prices tap ON tap.tariff_id = pt.id
    WHERE pt.subscription_plan_id = v_subscription.plan_id
    AND tap.asset_id = v_asset_id
    AND pt.effective_date <= now()
    ORDER BY pt.effective_date DESC
    LIMIT 1;

    -- Validar si el modelo de negocio permite extras (precio definido)
    IF v_tariff_price IS NULL THEN
        RETURN jsonb_build_object(
            'success', false, 
            'error_code', 'LIMIT_EXCEEDED_NO_UPSELL',
            'message', 'Plan limit reached and no extra branch price defined for this plan.'
        );
    END IF;

    -- 6. Calcular Prorrateo
    IF v_subscription.end_date IS NOT NULL AND v_subscription.end_date > now() THEN
        v_days_in_cycle := EXTRACT(DAY FROM (v_subscription.end_date - v_subscription.start_date));
        v_days_remaining := EXTRACT(DAY FROM (v_subscription.end_date - now()));
        
        IF v_days_in_cycle > 0 THEN
            v_prorated_amount := (v_tariff_price / v_days_in_cycle) * v_days_remaining * v_slots_needed;
        ELSE
            v_prorated_amount := v_tariff_price * v_slots_needed; -- Fallback seguro
        END IF;
    ELSE
        -- Sin fecha fin (ej. plan lifetime?), cobramos full o 0? Asumimos mes estándar (30 días)
        v_prorated_amount := v_tariff_price * v_slots_needed;
    END IF;

    -- Redondear a 2 decimales
    v_prorated_amount := ROUND(v_prorated_amount, 2);

    -- 7. Generar Factura (Invoice)
    -- Obtener datos del tenant para la factura
    SELECT billing_address, contact_email, legal_name, tax_id
    INTO v_billing_address, v_contact_email, v_legal_name, v_tax_id
    FROM public.tenants
    WHERE id = p_tenant_id;

    -- Generar número de factura simple (placeholder, debería usar una secuencia real)
    v_invoice_number := 'INV-' || floor(extract(epoch from now())); 

    INSERT INTO public.invoices (
        tenant_id, platform_id, invoice_number, issue_date, due_date, 
        subtotal_amount, total_tax_amount, total_amount, currency_id, status,
        billed_to_tenant_id, contact_email, billing_address
    )
    VALUES (
        p_tenant_id, p_platform_id, v_invoice_number, now(), now(),
        v_prorated_amount, 0, v_prorated_amount, v_currency_id, 'pending', -- Estado Pending para exigir pago
        p_tenant_id, v_contact_email, v_billing_address
    )
    RETURNING id INTO v_invoice_id;

    -- Crear Item de Factura
    INSERT INTO public.invoice_items (
        invoice_id, tenant_id, platform_id, item_type, description, 
        quantity, unit_price, total_price
    )
    VALUES (
        v_invoice_id, p_tenant_id, p_platform_id, 'asset_proration', 
        'Activación Sucursal Adicional (Prorrateo) x' || v_slots_needed,
        v_slots_needed, v_prorated_amount / GREATEST(v_slots_needed, 1), v_prorated_amount
    );

    -- 8. Registrar el nuevo asset recurrente en subscription_items
    -- Esto asegura que en el próximo ciclo de facturación se cobren estos extras automáticamente.
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
