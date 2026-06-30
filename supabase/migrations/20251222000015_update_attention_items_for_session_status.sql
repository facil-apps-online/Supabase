DROP FUNCTION IF EXISTS public.update_attention_items(p_payload jsonb);

CREATE OR REPLACE FUNCTION public.update_attention_items(p_payload jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  -- Extraer variables del payload
  p_attention_id uuid := (p_payload->>'p_attention_id')::uuid;
  p_tenant_id uuid := (p_payload->>'p_tenant_id')::uuid;
  p_branch_id uuid := (p_payload->>'p_branch_id')::uuid;
  p_total_amount numeric := (p_payload->>'p_total_amount')::numeric;
  p_notes text := p_payload->>'p_notes';
  p_services_to_upsert jsonb := p_payload->'p_services_to_upsert';
  p_products_to_upsert jsonb := p_payload->'p_products_to_upsert';
  p_combos_to_upsert jsonb := p_payload->'p_combos_to_upsert';
  p_service_ids_to_delete uuid[] := ARRAY(SELECT jsonb_array_elements_text(p_payload->'p_service_ids_to_delete')::uuid);
  p_product_ids_to_delete uuid[] := ARRAY(SELECT jsonb_array_elements_text(p_payload->'p_product_ids_to_delete')::uuid);
  p_combo_ids_to_delete uuid[] := ARRAY(SELECT jsonb_array_elements_text(p_payload->'p_combo_ids_to_delete')::uuid);

  -- Variables locales
  service_item jsonb;
  product_item jsonb;
  combo_item jsonb;
  v_subtotal_check numeric := 0;
  v_sessions_to_assign uuid[] := ARRAY[]::uuid[];
  v_sessions_to_revert uuid[] := ARRAY[]::uuid[];
  temp_session_id uuid;
BEGIN
  -- OBTENER SESIONES A REVERTIR (antes de borrar)
  SELECT array_agg(client_treatment_session_id) INTO v_sessions_to_revert
  FROM public.attention_services
  WHERE id = ANY(p_service_ids_to_delete) AND client_treatment_session_id IS NOT NULL;

  SELECT array_agg(client_treatment_session_id) INTO v_sessions_to_revert
  FROM public.attention_products
  WHERE id = ANY(p_product_ids_to_delete) AND client_treatment_session_id IS NOT NULL;

  -- 1. Eliminar ítems marcados para borrado
  IF array_length(p_service_ids_to_delete, 1) > 0 THEN
    DELETE FROM public.attention_services WHERE id = ANY(p_service_ids_to_delete) AND attention_id = p_attention_id;
  END IF;
  IF array_length(p_product_ids_to_delete, 1) > 0 THEN
    DELETE FROM public.attention_products WHERE id = ANY(p_product_ids_to_delete) AND attention_id = p_attention_id;
  END IF;
  IF array_length(p_combo_ids_to_delete, 1) > 0 THEN
    DELETE FROM public.attention_services WHERE attention_combo_id = ANY(p_combo_ids_to_delete);
    DELETE FROM public.attention_products WHERE attention_combo_id = ANY(p_combo_ids_to_delete);
    DELETE FROM public.attention_combos WHERE id = ANY(p_combo_ids_to_delete) AND attention_id = p_attention_id;
  END IF;

  -- 2. "Upsert" de servicios
  IF p_services_to_upsert IS NOT NULL THEN
    FOR service_item IN SELECT * FROM jsonb_array_elements(p_services_to_upsert) LOOP
      v_subtotal_check := v_subtotal_check + COALESCE((service_item->>'price')::numeric, 0);
      
      IF (service_item->>'id') IS NULL AND (service_item->>'client_treatment_session_id') IS NOT NULL THEN
        temp_session_id := (service_item->>'client_treatment_session_id')::uuid;
        IF NOT (temp_session_id = ANY(v_sessions_to_assign)) THEN
            v_sessions_to_assign := array_append(v_sessions_to_assign, temp_session_id);
        END IF;
      END IF;

      INSERT INTO public.attention_services (
          id, attention_id, service_id, user_id, service_price, duration_minutes, start_time, end_time, 
          status, is_parallel, parallel_group_id, offset_minutes, notes, tenant_id, branch_id, client_treatment_session_id
      ) VALUES (
        COALESCE((service_item->>'id')::uuid, gen_random_uuid()), p_attention_id, (service_item->>'service_id')::uuid, (service_item->>'user_id')::uuid,
        COALESCE((service_item->>'price')::numeric, 0), (service_item->>'duration_minutes')::integer, (service_item->>'start_time')::time, (service_item->>'end_time')::time,
        service_item->>'status', (service_item->>'is_parallel')::boolean, (service_item->>'parallel_group_id')::uuid,
        (service_item->>'offset_minutes')::integer, service_item->>'notes', p_tenant_id, p_branch_id, (service_item->>'client_treatment_session_id')::uuid
      ) ON CONFLICT (id) DO UPDATE SET
        service_id = EXCLUDED.service_id, user_id = EXCLUDED.user_id, service_price = EXCLUDED.service_price, duration_minutes = EXCLUDED.duration_minutes,
        start_time = EXCLUDED.start_time, end_time = EXCLUDED.end_time, status = EXCLUDED.status, is_parallel = EXCLUDED.is_parallel,
        parallel_group_id = EXCLUDED.parallel_group_id, offset_minutes = EXCLUDED.offset_minutes, notes = EXCLUDED.notes, 
        client_treatment_session_id = EXCLUDED.client_treatment_session_id;
    END LOOP;
  END IF;

  -- 3. "Upsert" de productos
  IF p_products_to_upsert IS NOT NULL THEN
    FOR product_item IN SELECT * FROM jsonb_array_elements(p_products_to_upsert) LOOP
      v_subtotal_check := v_subtotal_check + (COALESCE((product_item->>'price')::numeric, 0) * COALESCE((product_item->>'quantity')::integer, 1));
      
      IF (product_item->>'id') IS NULL AND (product_item->>'client_treatment_session_id') IS NOT NULL THEN
        temp_session_id := (product_item->>'client_treatment_session_id')::uuid;
        IF NOT (temp_session_id = ANY(v_sessions_to_assign)) THEN
            v_sessions_to_assign := array_append(v_sessions_to_assign, temp_session_id);
        END IF;
      END IF;

      INSERT INTO public.attention_products (
          id, attention_id, product_id, user_id, quantity, unit_price, total_price, tenant_id, branch_id, client_treatment_session_id
      ) VALUES (
        COALESCE((product_item->>'id')::uuid, gen_random_uuid()), p_attention_id, (product_item->>'product_id')::uuid,
        (product_item->>'user_id')::uuid, (product_item->>'quantity')::integer, COALESCE((product_item->>'price')::numeric, 0),
        (COALESCE((product_item->>'quantity')::integer, 1) * COALESCE((product_item->>'price')::numeric, 0)), p_tenant_id, p_branch_id, (product_item->>'client_treatment_session_id')::uuid
      ) ON CONFLICT (id) DO UPDATE SET
        product_id = EXCLUDED.product_id, user_id = EXCLUDED.user_id, quantity = EXCLUDED.quantity,
        unit_price = EXCLUDED.unit_price, total_price = EXCLUDED.total_price, client_treatment_session_id = EXCLUDED.client_treatment_session_id;
    END LOOP;
  END IF;

  -- 4. "Upsert" de combos
  IF p_combos_to_upsert IS NOT NULL THEN
    FOR combo_item IN SELECT * FROM jsonb_array_elements(p_combos_to_upsert) LOOP
      v_subtotal_check := v_subtotal_check + (COALESCE((combo_item->>'price')::numeric, 0) * COALESCE((combo_item->>'quantity')::integer, 1));
      INSERT INTO public.attention_combos (id, attention_id, combo_id, price, quantity, status, notes, tenant_id, branch_id)
      VALUES (
        COALESCE((combo_item->>'id')::uuid, gen_random_uuid()), p_attention_id, (combo_item->>'combo_id')::uuid,
        (combo_item->>'price')::numeric, COALESCE((combo_item->>'quantity')::integer, 1),
        combo_item->>'status', combo_item->>'notes', p_tenant_id, p_branch_id
      ) ON CONFLICT (id) DO UPDATE SET
        combo_id = EXCLUDED.combo_id, price = EXCLUDED.price, quantity = EXCLUDED.quantity,
        status = EXCLUDED.status, notes = EXCLUDED.notes;
    END LOOP;
  END IF;

  -- 5. Verificación de seguridad y actualización del total de la atención
  IF p_total_amount < v_subtotal_check THEN
    RAISE EXCEPTION 'Mismatched total amount during update. Frontend total (%) is less than backend-calculated subtotal (%).', p_total_amount, v_subtotal_check;
  END IF;

  UPDATE public.attentions
  SET total_amount = p_total_amount, notes = p_notes, updated_at = now()
  WHERE id = p_attention_id;
  
  -- 6. ACTUALIZAR ESTADOS DE SESIONES (NUEVO)
  IF array_length(v_sessions_to_revert, 1) > 0 THEN
      UPDATE public.client_treatment_sessions
      SET status = 'Pendiente', attention_id = NULL
      WHERE id = ANY(v_sessions_to_revert);
  END IF;
  
  IF array_length(v_sessions_to_assign, 1) > 0 THEN
      UPDATE public.client_treatment_sessions
      SET status = 'Cita Asignada', attention_id = p_attention_id
      WHERE id = ANY(v_sessions_to_assign);
  END IF;

END;
$function$;