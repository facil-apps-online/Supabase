
-- Primero, eliminamos la firma de función obsoleta para evitar conflictos.
-- Esta es la versión que NO tiene el parámetro p_total_amount.
DROP FUNCTION IF EXISTS public.create_full_attention(
  p_client_id uuid,
  p_attention_datetime timestamp with time zone,
  p_notes text,
  p_services jsonb,
  p_products jsonb,
  p_combos jsonb,
  p_tenant_id uuid,
  p_branch_id uuid
);

-- Ahora, creamos la versión nueva y corregida de la función.
CREATE OR REPLACE FUNCTION public.create_full_attention(
  p_client_id uuid,
  p_attention_datetime timestamp with time zone,
  p_notes text,
  p_services jsonb,
  p_products jsonb,
  p_combos jsonb,
  p_tenant_id uuid,
  p_branch_id uuid,
  p_total_amount numeric -- Aunque este parámetro se ignora, lo mantenemos por compatibilidad con el frontend.
)
RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
    v_attention_id uuid;
    v_service jsonb;
    v_product jsonb;
    v_combo jsonb;
    v_attention_combo_id uuid;
    v_combo_service_data jsonb;
    v_recalculated_total_amount numeric := 0;
    v_current_service_price numeric;
    v_current_product_price numeric;
    v_client_treatment_session_id uuid;
BEGIN
    -- Insert the main attention record, INICIALMENTE con total 0.
    -- El total real se recalculará y actualizará al final.
    INSERT INTO public.attentions (client_id, attention_datetime, notes, total_amount, tenant_id, branch_id, status)
    VALUES (p_client_id, p_attention_datetime, p_notes, 0, p_tenant_id, p_branch_id, 'Confirmada')
    RETURNING id INTO v_attention_id;

    -- Insert combos y acumular su valor
    IF jsonb_array_length(p_combos) > 0 THEN
        FOR v_combo IN SELECT * FROM jsonb_array_elements(p_combos)
        LOOP
            v_recalculated_total_amount := v_recalculated_total_amount + (COALESCE((v_combo->>'price')::numeric, 0) * COALESCE((v_combo->>'quantity')::integer, 1));
            
            INSERT INTO public.attention_combos (
                attention_id, combo_id, price, quantity, notes, tenant_id, branch_id, status
            )
            VALUES (
                v_attention_id, 
                (v_combo->>'combo_id')::uuid, 
                COALESCE((v_combo->>'price')::numeric, 0), 
                COALESCE((v_combo->>'quantity')::integer, 1), 
                v_combo->>'notes', 
                p_tenant_id, 
                p_branch_id, 
                'Pendiente'
            )
            RETURNING id INTO v_attention_combo_id;

            -- Asociar el ID del combo de atención a los servicios del payload
            FOR v_combo_service_data IN SELECT * FROM jsonb_array_elements(p_services)
            LOOP
                IF (v_combo_service_data->>'combo_id')::uuid = (v_combo->>'combo_id')::uuid THEN
                    v_combo_service_data := v_combo_service_data || jsonb_build_object('attention_combo_id', v_attention_combo_id);
                END IF;
            END LOOP;
        END LOOP;
    END IF;

    -- Insert services (standalone y de combos)
    IF jsonb_array_length(p_services) > 0 THEN
        FOR v_service IN SELECT * FROM jsonb_array_elements(p_services)
        LOOP
            v_client_treatment_session_id := NULL;
            IF (v_service->>'client_treatment_session_id') IS NOT NULL AND (v_service->>'client_treatment_session_id') != 'null' THEN
                v_client_treatment_session_id := (v_service->>'client_treatment_session_id')::uuid;
            END IF;

            v_current_service_price := COALESCE((v_service->>'price')::numeric, 0);

            -- LÓGICA DE PRECIOS DE TRATAMIENTO
            IF v_client_treatment_session_id IS NOT NULL THEN
                SELECT cts.payment_amount INTO v_current_service_price
                FROM public.client_treatment_sessions cts
                WHERE cts.id = v_client_treatment_session_id AND cts.tenant_id = p_tenant_id;
            END IF;

            v_recalculated_total_amount := v_recalculated_total_amount + v_current_service_price;

            SELECT ac.id INTO v_attention_combo_id
            FROM public.attention_combos ac
            WHERE ac.attention_id = v_attention_id AND ac.combo_id = (v_service->>'combo_id')::uuid;

            INSERT INTO public.attention_services (
                attention_id, service_id, user_id, service_price, notes, tenant_id, branch_id, 
                duration_minutes, start_time, end_time, is_parallel, offset_minutes, status, combo_id, client_treatment_session_id
            )
            VALUES (
                v_attention_id, 
                (v_service->>'service_id')::uuid, 
                (v_service->>'user_id')::uuid,
                v_current_service_price, 
                v_service->>'notes', 
                p_tenant_id, 
                p_branch_id, 
                (v_service->>'duration')::integer, 
                (v_service->>'start_time')::time, 
                (v_service->>'end_time')::time,
                (v_service->>'is_parallel')::boolean,
                (v_service->>'offset_minutes')::integer,
                'Pendiente',
                v_attention_combo_id,
                v_client_treatment_session_id
            );
        END LOOP;
    END IF;

    -- Insert products (standalone y de combos)
    IF jsonb_array_length(p_products) > 0 THEN
        FOR v_product IN SELECT * FROM jsonb_array_elements(p_products)
        LOOP
            v_client_treatment_session_id := NULL;
            IF (v_product->>'client_treatment_session_id') IS NOT NULL AND (v_product->>'client_treatment_session_id') != 'null' THEN
                v_client_treatment_session_id := (v_product->>'client_treatment_session_id')::uuid;
            END IF;

            v_current_product_price := COALESCE((v_product->>'unit_price')::numeric, 0);

            -- LÓGICA DE PRECIOS DE TRATAMIENTO
            IF v_client_treatment_session_id IS NOT NULL THEN
                SELECT cts.payment_amount INTO v_current_product_price
                FROM public.client_treatment_sessions cts
                WHERE cts.id = v_client_treatment_session_id AND cts.tenant_id = p_tenant_id;
            END IF;
            
            v_recalculated_total_amount := v_recalculated_total_amount + (v_current_product_price * COALESCE((v_product->>'quantity')::integer, 1));

            SELECT ac.id INTO v_attention_combo_id
            FROM public.attention_combos ac
            WHERE ac.attention_id = v_attention_id AND ac.combo_id = (v_product->>'combo_id')::uuid;

            INSERT INTO public.attention_products (
                attention_id, product_id, user_id, quantity, unit_price, total_price, tenant_id, branch_id, combo_id, client_treatment_session_id
            )
            VALUES (
                v_attention_id, 
                (v_product->>'product_id')::uuid, 
                (v_product->>'user_id')::uuid, 
                COALESCE((v_product->>'quantity')::integer, 1), 
                v_current_product_price, 
                v_current_product_price * COALESCE((v_product->>'quantity')::integer, 1), 
                p_tenant_id, 
                p_branch_id,
                v_attention_combo_id,
                v_client_treatment_session_id
            );
        END LOOP;
    END IF;
    
    -- Actualizar el monto total de la atención con el valor recalculado y seguro.
    UPDATE public.attentions
    SET total_amount = v_recalculated_total_amount
    WHERE id = v_attention_id;

    -- Enqueue client notifications
    BEGIN
        PERFORM public.queue_client_email(
            p_tenant_id := p_tenant_id,
            p_client_id := p_client_id,
            p_template_type := 'new_attention',
            p_template_data := jsonb_build_object('attention_datetime', p_attention_datetime)
        );
    EXCEPTION WHEN others THEN
        RAISE WARNING 'Failed to queue client email for new attention (client_id: %): %', p_client_id, SQLERRM;
    END;

    BEGIN
        PERFORM public.queue_client_whatsapp(
            p_tenant_id := p_tenant_id,
            p_client_id := p_client_id,
            p_template_name := 'new_attention_whatsapp',
            p_template_params := jsonb_build_object('attention_datetime', p_attention_datetime)
        );
    EXCEPTION WHEN others THEN
        RAISE WARNING 'Failed to queue client WhatsApp for new attention (client_id: %): %', p_client_id, SQLERRM;
    END;

    RETURN v_attention_id;
END;
$$;
