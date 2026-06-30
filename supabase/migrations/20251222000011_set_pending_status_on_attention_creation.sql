-- Limpieza de firmas de funciones anteriores para evitar conflictos.
DROP FUNCTION IF EXISTS public.create_full_attention(p_client_id uuid, p_attention_datetime timestamp with time zone, p_notes text, p_services jsonb, p_products jsonb, p_combos jsonb, p_tenant_id uuid, p_branch_id uuid, p_total_amount numeric);
DROP FUNCTION IF EXISTS public.create_full_attention(p_client_id uuid, p_attention_datetime timestamp with time zone, p_notes text, p_services jsonb, p_products jsonb, p_combos jsonb, p_payments jsonb, p_tenant_id uuid, p_branch_id uuid, p_total_amount numeric);


CREATE OR REPLACE FUNCTION public.create_full_attention(
  p_client_id uuid,
  p_attention_datetime timestamp with time zone,
  p_notes text,
  p_services jsonb,
  p_products jsonb,
  p_combos jsonb,
  p_payments jsonb,
  p_tenant_id uuid,
  p_branch_id uuid,
  p_total_amount numeric
)
RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
    v_attention_id uuid;
    v_service jsonb;
    v_product jsonb;
    v_combo jsonb;
    v_payment jsonb;
    v_attention_combo_id uuid;
    v_combo_service_data jsonb;
    v_recalculated_total numeric := 0;
BEGIN
    -- 1. Calcular el total real a partir de todos los payloads
    IF jsonb_array_length(p_services) > 0 THEN
        FOR v_service IN SELECT * FROM jsonb_array_elements(p_services) LOOP
            v_recalculated_total := v_recalculated_total + COALESCE((v_service->>'price')::numeric, 0);
        END LOOP;
    END IF;
    IF jsonb_array_length(p_products) > 0 THEN
        FOR v_product IN SELECT * FROM jsonb_array_elements(p_products) LOOP
            v_recalculated_total := v_recalculated_total + (COALESCE((v_product->>'unit_price')::numeric, 0) * COALESCE((v_product->>'quantity')::integer, 1));
        END LOOP;
    END IF;
    IF jsonb_array_length(p_combos) > 0 THEN
        FOR v_combo IN SELECT * FROM jsonb_array_elements(p_combos) LOOP
            v_recalculated_total := v_recalculated_total + COALESCE((v_combo->>'price')::numeric, 0);
        END LOOP;
    END IF;
    IF jsonb_array_length(p_payments) > 0 THEN
        FOR v_payment IN SELECT * FROM jsonb_array_elements(p_payments) LOOP
            v_recalculated_total := v_recalculated_total + COALESCE((v_payment->>'price')::numeric, 0);
        END LOOP;
    END IF;

    -- 2. Insertar la atención con estado 'Pendiente'
    INSERT INTO public.attentions (client_id, attention_datetime, notes, total_amount, tenant_id, branch_id, status)
    VALUES (p_client_id, p_attention_datetime, p_notes, v_recalculated_total, p_tenant_id, p_branch_id, 'Pendiente') -- MODIFICADO
    RETURNING id INTO v_attention_id;

    -- 3. Insertar los ítems (servicios, productos, combos) como antes
    IF jsonb_array_length(p_combos) > 0 THEN
        FOR v_combo IN SELECT * FROM jsonb_array_elements(p_combos) LOOP
            INSERT INTO public.attention_combos (
                attention_id, combo_id, price, quantity, notes, tenant_id, branch_id, status
            ) VALUES (
                v_attention_id, (v_combo->>'combo_id')::uuid, COALESCE((v_combo->>'price')::numeric, 0), 
                COALESCE((v_combo->>'quantity')::integer, 1), v_combo->>'notes', p_tenant_id, p_branch_id, 'Pendiente'
            ) RETURNING id INTO v_attention_combo_id;
            
            FOR v_combo_service_data IN SELECT * FROM jsonb_array_elements(p_services) LOOP
                IF (v_combo_service_data->>'combo_id')::uuid = (v_combo->>'combo_id')::uuid THEN
                    v_combo_service_data := v_combo_service_data || jsonb_build_object('attention_combo_id', v_attention_combo_id);
                END IF;
            END LOOP;
        END LOOP;
    END IF;

    IF jsonb_array_length(p_services) > 0 THEN
        FOR v_service IN SELECT * FROM jsonb_array_elements(p_services) LOOP
            SELECT ac.id INTO v_attention_combo_id FROM public.attention_combos ac WHERE ac.attention_id = v_attention_id AND ac.combo_id = (v_service->>'combo_id')::uuid;
            INSERT INTO public.attention_services (
                attention_id, service_id, user_id, service_price, notes, tenant_id, branch_id, 
                duration_minutes, start_time, end_time, is_parallel, offset_minutes, status, combo_id, client_treatment_session_id
            ) VALUES (
                v_attention_id, (v_service->>'service_id')::uuid, (v_service->>'user_id')::uuid,
                COALESCE((v_service->>'price')::numeric, 0), v_service->>'notes', p_tenant_id, p_branch_id, 
                (v_service->>'duration')::integer, (v_service->>'start_time')::time, (v_service->>'end_time')::time,
                (v_service->>'is_parallel')::boolean, (v_service->>'offset_minutes')::integer, 'Pendiente',
                v_attention_combo_id, (v_service->>'client_treatment_session_id')::uuid
            );
        END LOOP;
    END IF;

    IF jsonb_array_length(p_products) > 0 THEN
        FOR v_product IN SELECT * FROM jsonb_array_elements(p_products) LOOP
            SELECT ac.id INTO v_attention_combo_id FROM public.attention_combos ac WHERE ac.attention_id = v_attention_id AND ac.combo_id = (v_product->>'combo_id')::uuid;
            INSERT INTO public.attention_products (
                attention_id, product_id, user_id, quantity, unit_price, total_price, tenant_id, branch_id, combo_id, client_treatment_session_id
            ) VALUES (
                v_attention_id, (v_product->>'product_id')::uuid, (v_product->>'user_id')::uuid, 
                COALESCE((v_product->>'quantity')::integer, 1), COALESCE((v_product->>'unit_price')::numeric, 0), 
                COALESCE((v_product->>'unit_price')::numeric, 0) * COALESCE((v_product->>'quantity')::integer, 1), 
                p_tenant_id, p_branch_id, v_attention_combo_id, (v_product->>'client_treatment_session_id')::uuid
            );
        END LOOP;
    END IF;

    -- 4. Notificaciones (se mantienen igual)
    BEGIN
        PERFORM public.queue_client_email(p_tenant_id, p_client_id, 'new_attention', jsonb_build_object('attention_datetime', p_attention_datetime));
    EXCEPTION WHEN others THEN
        RAISE WARNING 'Failed to queue client email for new attention (client_id: %): %', p_client_id, SQLERRM;
    END;
    BEGIN
        PERFORM public.queue_client_whatsapp(p_tenant_id, p_client_id, 'new_attention_whatsapp', jsonb_build_object('attention_datetime', p_attention_datetime));
    EXCEPTION WHEN others THEN
        RAISE WARNING 'Failed to queue client WhatsApp for new attention (client_id: %): %', p_client_id, SQLERRM;
    END;

    RETURN v_attention_id;
END;
$$;