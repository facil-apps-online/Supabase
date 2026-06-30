
CREATE OR REPLACE FUNCTION public.update_attention_items(p_payload jsonb)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  -- Extract variables from payload
  p_attention_id uuid := (p_payload->>'p_attention_id')::uuid;
  p_tenant_id uuid := (p_payload->>'p_tenant_id')::uuid;
  p_branch_id uuid := (p_payload->>'p_branch_id')::uuid;
  p_services_to_upsert jsonb := p_payload->'p_services_to_upsert';
  p_products_to_upsert jsonb := p_payload->'p_products_to_upsert';
  p_combos_to_upsert jsonb := p_payload->'p_combos_to_upsert';
  p_service_ids_to_delete uuid[] := ARRAY(SELECT jsonb_array_elements_text(p_payload->'p_service_ids_to_delete')::uuid);
  p_product_ids_to_delete uuid[] := ARRAY(SELECT jsonb_array_elements_text(p_payload->'p_product_ids_to_delete')::uuid);
  p_combo_ids_to_delete uuid[] := ARRAY(SELECT jsonb_array_elements_text(p_payload->'p_combo_ids_to_delete')::uuid);

  -- Local variables
  service_item jsonb;
  product_item jsonb;
  combo_item jsonb;
  v_combo_item record;
  v_attention_combo_id uuid;
  v_service_data record;
  v_branch_product record;
  v_recalculated_total numeric := 0;
  v_current_service_price numeric;
  v_current_product_price numeric;
  v_client_treatment_session_id uuid;
BEGIN
  -- 1. Delete items marked for deletion
  IF array_length(p_service_ids_to_delete, 1) > 0 THEN
    DELETE FROM public.attention_services WHERE id = ANY(p_service_ids_to_delete) AND attention_id = p_attention_id;
  END IF;

  IF array_length(p_product_ids_to_delete, 1) > 0 THEN
    DELETE FROM public.attention_products WHERE id = ANY(p_product_ids_to_delete) AND attention_id = p_attention_id;
  END IF;

  IF array_length(p_combo_ids_to_delete, 1) > 0 THEN
    -- This should cascade, but we are explicit for clarity
    DELETE FROM public.attention_services WHERE attention_combo_id = ANY(p_combo_ids_to_delete);
    DELETE FROM public.attention_products WHERE attention_combo_id = ANY(p_combo_ids_to_delete);
    DELETE FROM public.attention_combos WHERE id = ANY(p_combo_ids_to_delete) AND attention_id = p_attention_id;
  END IF;

  -- 2. Upsert services
  FOR service_item IN SELECT * FROM jsonb_array_elements(p_services_to_upsert)
  LOOP
    v_client_treatment_session_id := NULL;
    IF (service_item->>'client_treatment_session_id') IS NOT NULL AND (service_item->>'client_treatment_session_id') <> 'null' THEN
        v_client_treatment_session_id := (service_item->>'client_treatment_session_id')::uuid;
    END IF;

    v_current_service_price := (service_item->>'price')::numeric;

    -- LÓGICA DE PRECIOS DE TRATAMIENTO
    IF v_client_treatment_session_id IS NOT NULL THEN
        SELECT cts.payment_amount INTO v_current_service_price
        FROM public.client_treatment_sessions cts
        WHERE cts.id = v_client_treatment_session_id AND cts.tenant_id = p_tenant_id;
    END IF;

    INSERT INTO public.attention_services (
        id, attention_id, service_id, user_id, service_price, duration_minutes, start_time, end_time, 
        status, is_parallel, parallel_group_id, offset_minutes, notes, tenant_id, branch_id, client_treatment_session_id
    )
    VALUES (
      COALESCE((service_item->>'id')::uuid, gen_random_uuid()), p_attention_id, (service_item->>'service_id')::uuid, (service_item->>'user_id')::uuid,
      v_current_service_price, (service_item->>'duration_minutes')::integer, (service_item->>'start_time')::time, (service_item->>'end_time')::time,
      service_item->>'status', (service_item->>'is_parallel')::boolean, (service_item->>'parallel_group_id')::uuid,
      (service_item->>'offset_minutes')::integer, service_item->>'notes', p_tenant_id, p_branch_id, v_client_treatment_session_id
    ) ON CONFLICT (id) DO UPDATE SET
      service_id = EXCLUDED.service_id,
      user_id = EXCLUDED.user_id,
      service_price = EXCLUDED.service_price, -- Usa el precio determinado
      duration_minutes = EXCLUDED.duration_minutes,
      start_time = EXCLUDED.start_time,
      end_time = EXCLUDED.end_time,
      status = EXCLUDED.status,
      is_parallel = EXCLUDED.is_parallel,
      parallel_group_id = EXCLUDED.parallel_group_id,
      offset_minutes = EXCLUDED.offset_minutes,
      notes = EXCLUDED.notes,
      client_treatment_session_id = EXCLUDED.client_treatment_session_id;
  END LOOP;

  -- 3. Upsert products
  FOR product_item IN SELECT * FROM jsonb_array_elements(p_products_to_upsert)
  LOOP
    v_client_treatment_session_id := NULL;
    IF (product_item->>'client_treatment_session_id') IS NOT NULL AND (product_item->>'client_treatment_session_id') <> 'null' THEN
        v_client_treatment_session_id := (product_item->>'client_treatment_session_id')::uuid;
    END IF;

    v_current_product_price := (product_item->>'price')::numeric;

    -- LÓGICA DE PRECIOS DE TRATAMIENTO
    IF v_client_treatment_session_id IS NOT NULL THEN
        SELECT cts.payment_amount INTO v_current_product_price
        FROM public.client_treatment_sessions cts
        WHERE cts.id = v_client_treatment_session_id AND cts.tenant_id = p_tenant_id;
    END IF;

    INSERT INTO public.attention_products (
        id, attention_id, product_id, user_id, quantity, unit_price, total_price, tenant_id, branch_id, client_treatment_session_id
    )
    VALUES (
      COALESCE((product_item->>'id')::uuid, gen_random_uuid()), p_attention_id, (product_item->>'product_id')::uuid,
      (product_item->>'user_id')::uuid, (product_item->>'quantity')::integer, v_current_product_price,
      (product_item->>'quantity')::integer * v_current_product_price, p_tenant_id, p_branch_id, v_client_treatment_session_id
    ) ON CONFLICT (id) DO UPDATE SET
      product_id = EXCLUDED.product_id,
      user_id = EXCLUDED.user_id,
      quantity = EXCLUDED.quantity,
      unit_price = EXCLUDED.unit_price,
      total_price = EXCLUDED.total_price,
      client_treatment_session_id = EXCLUDED.client_treatment_session_id;
  END LOOP;

  -- 4. Upsert combos (la lógica de precios de tratamiento no aplica a combos directamente, sino a sus items)
  FOR combo_item IN SELECT * FROM jsonb_array_elements(p_combos_to_upsert)
  LOOP
    -- Upsert del combo principal
    INSERT INTO public.attention_combos (id, attention_id, combo_id, price, quantity, status, notes, tenant_id, branch_id)
    VALUES (
      COALESCE((combo_item->>'id')::uuid, gen_random_uuid()), p_attention_id, (combo_item->>'combo_id')::uuid,
      (combo_item->>'price')::numeric, 
      COALESCE((combo_item->>'quantity')::integer, 1),
      combo_item->>'status', combo_item->>'notes', p_tenant_id, p_branch_id
    ) ON CONFLICT (id) DO UPDATE SET
      combo_id = EXCLUDED.combo_id,
      price = EXCLUDED.price,
      quantity = EXCLUDED.quantity,
      status = EXCLUDED.status,
      notes = EXCLUDED.notes
    RETURNING id INTO v_attention_combo_id;
    
    -- Lógica para añadir items si es un combo nuevo
    IF (combo_item->>'id') IS NULL THEN
      FOR v_combo_item IN SELECT * FROM public.combo_items WHERE combo_id = (combo_item->>'combo_id')::uuid
      LOOP
        IF v_combo_item.service_id IS NOT NULL THEN
          SELECT s.duration_minutes, bs.selling_price INTO v_service_data FROM public.services s
          LEFT JOIN public.branch_services bs ON s.id = bs.service_id AND bs.branch_id = p_branch_id
          WHERE s.id = v_combo_item.service_id;

          INSERT INTO public.attention_services(attention_id, service_id, service_price, notes, tenant_id, branch_id, duration_minutes, attention_combo_id, status)
          VALUES (p_attention_id, v_combo_item.service_id, 0, 'Parte de combo', p_tenant_id, p_branch_id, COALESCE(v_service_data.duration_minutes, 0), v_attention_combo_id, 'Pendiente');
        END IF;

        IF v_combo_item.product_id IS NOT NULL THEN
          SELECT selling_price INTO v_branch_product FROM public.branch_products WHERE product_id = v_combo_item.product_id AND branch_id = p_branch_id;
          INSERT INTO public.attention_products(attention_id, product_id, quantity, unit_price, total_price, tenant_id, branch_id, attention_combo_id)
          VALUES (p_attention_id, v_combo_item.product_id, v_combo_item.quantity, 0, 0, p_tenant_id, p_branch_id, v_attention_combo_id);
        END IF;
      END LOOP;
    END IF;
  END LOOP;

  -- 5. Recalcular el total de la atención
  SELECT COALESCE(SUM(total), 0) INTO v_recalculated_total
  FROM (
      SELECT COALESCE(service_price, 0) as total FROM public.attention_services WHERE attention_id = p_attention_id
      UNION ALL
      SELECT COALESCE(total_price, 0) FROM public.attention_products WHERE attention_id = p_attention_id
      UNION ALL
      SELECT COALESCE(price, 0) * COALESCE(quantity, 1) FROM public.attention_combos WHERE attention_id = p_attention_id
  ) as attention_totals;

  UPDATE public.attentions
  SET total_amount = v_recalculated_total, updated_at = now()
  WHERE id = p_attention_id;

END;
$$;
