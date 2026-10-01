-- Parche Lote 2: Funciones de Negocio (Facturación, Atenciones, Sucursales, TVs)

DROP FUNCTION IF EXISTS "public"."add_branch_social_network"("uuid", "public"."social_network", "text");
CREATE OR REPLACE FUNCTION "public"."add_branch_social_network"("p_branch_id" "uuid", "p_network" "public"."social_network", "p_url" "text", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS "public"."branch_social_networks"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    new_record public.branch_social_networks;
BEGIN
    INSERT INTO public.branch_social_networks (branch_id, network, url)
    VALUES (p_branch_id, p_network, p_url)
    RETURNING * INTO new_record;
    RETURN new_record;
END;
$$;

DROP FUNCTION IF EXISTS "public"."delete_branch_social_network"("uuid", "uuid");
CREATE OR REPLACE FUNCTION "public"."delete_branch_social_network"("p_id" "uuid", "p_branch_id" "uuid", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    DELETE FROM public.branch_social_networks
    WHERE id = p_id AND branch_id = p_branch_id;
END;
$$;

DROP FUNCTION IF EXISTS "public"."generate_invoice_for_attention"("uuid");
CREATE OR REPLACE FUNCTION "public"."generate_invoice_for_attention"("p_attention_id" "uuid", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_invoice_id UUID;
    v_attention RECORD;
    v_tenant_id UUID;
    v_client_id UUID;
    v_branch_id UUID;
    v_invoice_item_id UUID;
    v_service RECORD;
    v_product RECORD;
    v_subtotal NUMERIC := 0;
    v_total_tax NUMERIC := 0;
    v_currency_id UUID;
BEGIN
    -- Get attention details
    SELECT * INTO v_attention FROM public.attentions WHERE id = p_attention_id;
    v_tenant_id := v_attention.tenant_id;
    v_client_id := v_attention.client_id;
    v_branch_id := v_attention.branch_id;

    -- Check if an invoice already exists for this attention
    SELECT id INTO v_invoice_id FROM public.invoices WHERE attention_id = p_attention_id;
    IF v_invoice_id IS NOT NULL THEN
        -- Enqueue notifications for the existing invoice
        BEGIN
            PERFORM public.queue_client_email(p_tenant_id := v_tenant_id, p_client_id := v_client_id, p_template_type := 'invoice_generated', p_template_data := '{}'::jsonb);
        EXCEPTION WHEN others THEN RAISE WARNING 'Failed to queue client invoice email for attention_id %: %', p_attention_id, SQLERRM; END;
        BEGIN
            PERFORM public.queue_client_whatsapp(p_tenant_id := v_tenant_id, p_client_id := v_client_id, p_template_name := 'invoice_generated_whatsapp', p_template_params := '{}'::jsonb);
        EXCEPTION WHEN others THEN RAISE WARNING 'Failed to queue client invoice WhatsApp for attention_id %: %', p_attention_id, SQLERRM; END;
        RETURN v_invoice_id;
    END IF;

    -- Get default currency from tenant
    SELECT default_currency_id INTO v_currency_id FROM public.tenants WHERE id = v_tenant_id;
    IF v_currency_id IS NULL THEN
        RAISE EXCEPTION 'Tenant % does not have a default_currency_id set.', v_tenant_id;
    END IF;

    -- Create invoice header
    INSERT INTO public.invoices (
        tenant_id, platform_id, billed_to_client_id, attention_id, invoice_number, status, subtotal_amount, total_tax_amount, total_amount, issue_date, due_date, currency_id
    ) VALUES (
        v_tenant_id, p_platform_id, v_client_id, p_attention_id, 'INV-' || to_char(CURRENT_DATE, 'YYYYMMDD') || '-' || (SELECT count(*) + 1 FROM invoices WHERE tenant_id = v_tenant_id), 'paid', 0, 0, v_attention.total_amount, CURRENT_DATE, CURRENT_DATE, v_currency_id
    ) RETURNING id INTO v_invoice_id;

    -- Create invoice items for services
    FOR v_service IN SELECT * FROM public.attention_services WHERE attention_id = p_attention_id LOOP
        INSERT INTO public.invoice_items (invoice_id, service_id, item_type, description, quantity, unit_price, total_price) 
        VALUES (v_invoice_id, v_service.service_id, 'SERVICE', (SELECT name FROM public.services WHERE id = v_service.service_id), 1, v_service.price, v_service.price) RETURNING total_price INTO v_subtotal;
        v_subtotal := v_subtotal + v_service.price;
    END LOOP;

    -- Create invoice items for products
    FOR v_product IN SELECT * FROM public.attention_products WHERE attention_id = p_attention_id LOOP
        INSERT INTO public.invoice_items (invoice_id, product_id, item_type, description, quantity, unit_price, total_price) 
        VALUES (v_invoice_id, v_product.product_id, 'PRODUCT', (SELECT name FROM public.products WHERE id = v_product.product_id), v_product.quantity, v_product.price, v_product.price * v_product.quantity) RETURNING total_price INTO v_subtotal;
        v_subtotal := v_subtotal + (v_product.price * v_product.quantity);
    END LOOP;

    -- Update invoice with total amounts
    UPDATE public.invoices SET subtotal_amount = v_subtotal, total_tax_amount = v_total_tax, total_amount = v_subtotal + v_total_tax WHERE id = v_invoice_id;

    -- Enqueue notifications for the new invoice
    BEGIN
        PERFORM public.queue_client_email(p_tenant_id := v_tenant_id, p_client_id := v_client_id, p_template_type := 'invoice_generated', p_template_data := '{}'::jsonb);
    EXCEPTION WHEN others THEN RAISE WARNING 'Failed to queue client invoice email for attention_id %: %', p_attention_id, SQLERRM; END;
    BEGIN
        PERFORM public.queue_client_whatsapp(p_tenant_id := v_tenant_id, p_client_id := v_client_id, p_template_name := 'invoice_generated_whatsapp', p_template_params := '{}'::jsonb);
    EXCEPTION WHEN others THEN RAISE WARNING 'Failed to queue client invoice WhatsApp for attention_id %: %', p_attention_id, SQLERRM; END;

    RETURN v_invoice_id;
END;
$$;

DROP FUNCTION IF EXISTS "public"."generate_invoice_for_subscription"("uuid");
CREATE OR REPLACE FUNCTION "public"."generate_invoice_for_subscription"("p_subscription_id" "uuid", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS "uuid"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_tenant_id UUID;
    v_branch_id UUID;
    v_plan_id UUID;
    v_country_id UUID;
    v_currency_id UUID;
    v_invoice_id UUID;
    v_invoice_item_id UUID;
    v_calculated_price NUMERIC;
    v_calculated_extra_branch_price NUMERIC;
    v_plan_name TEXT;
    v_description TEXT;
    v_subtotal NUMERIC := 0;
    v_total_taxes NUMERIC := 0;
    v_tax_record RECORD;
BEGIN
    -- 1. Obtener datos de la suscripción y del tenant
    SELECT
        ts.tenant_id, ts.branch_id, ts.subscription_plan_id, t.country_id, t.default_currency_id
    INTO
        v_tenant_id, v_branch_id, v_plan_id, v_country_id, v_currency_id
    FROM public.tenant_subscriptions ts
    JOIN public.tenants t ON ts.tenant_id = t.id
    WHERE ts.id = p_subscription_id;

    IF v_tenant_id IS NULL THEN
        RAISE EXCEPTION 'Suscripción con ID % no encontrada.', p_subscription_id;
    END IF;

    -- 2. Obtener el precio calculado para el plan y país específicos
    -- Reutilizamos la lógica de la función get_calculated_plan_prices
    SELECT
        gcp.plan_name,
        gcp.calculated_price,
        gcp.calculated_extra_branch_price
    INTO
        v_plan_name,
        v_calculated_price,
        v_calculated_extra_branch_price
    FROM public.get_calculated_plan_prices() gcp
    WHERE gcp.plan_id = v_plan_id AND gcp.country_id = v_country_id
    LIMIT 1;

    IF v_calculated_price IS NULL THEN
        RAISE EXCEPTION 'No se pudo calcular el precio para el plan ID % y país ID %.', v_plan_id, v_country_id;
    END IF;

    -- 3. Crear la cabecera de la factura (con totales iniciales en 0)
    INSERT INTO public.invoices (
        tenant_id, platform_id, billed_to_tenant_id, issue_date, due_date,
        subtotal_amount, total_tax_amount, total_amount, currency_id,
        invoice_number, status
    ) VALUES (
        '00000000-0000-0000-0000-000000000000', -- Factura emitida por el superadmin
        v_tenant_id,
        CURRENT_DATE,
        CURRENT_DATE + INTERVAL '1 month',
        0, 0, 0,
        v_currency_id,
        'INV-' || to_char(CURRENT_DATE, 'YYYYMMDD') || '-' || (SELECT count(*) + 1 FROM invoices),
        'draft'
    ) RETURNING id INTO v_invoice_id;

    -- 4. Crear el item de la factura para la suscripción
    v_description := 'Suscripción Plan: ' || v_plan_name;
    v_subtotal := v_calculated_price;

    INSERT INTO public.invoice_items (
        invoice_id, subscription_plan_id, item_type, description, quantity, unit_price, total_price
    ) VALUES (
        v_invoice_id, v_plan_id, 'SUBSCRIPTION_PLAN', v_description, 1, v_calculated_price, v_subtotal
    ) RETURNING id INTO v_invoice_item_id;

    -- 5. Calcular y aplicar impuestos para este item
    FOR v_tax_record IN
        SELECT id, rate FROM public.generic_taxes WHERE country_id = v_country_id AND is_active = TRUE
    LOOP
        DECLARE
            v_tax_amount NUMERIC;
        BEGIN
            v_tax_amount := v_subtotal * (v_tax_record.rate / 100);
            v_total_taxes := v_total_taxes + v_tax_amount;

            INSERT INTO public.invoice_item_taxes (
                invoice_item_id, tax_id, taxable_amount, calculated_tax_amount
            ) VALUES (
                v_invoice_item_id, v_tax_record.id, v_subtotal, v_tax_amount
            );
        END;
    END LOOP;

    -- 6. Actualizar la factura con los totales finales
    UPDATE public.invoices
    SET
        subtotal_amount = v_subtotal,
        total_tax_amount = v_total_taxes,
        total_amount = v_subtotal + v_total_taxes
    WHERE id = v_invoice_id;

    -- 7. Devolver el ID de la factura creada
    RETURN v_invoice_id;
END;
$$;

DROP FUNCTION IF EXISTS "public"."get_managed_tvs"();
CREATE OR REPLACE FUNCTION "public"."get_managed_tvs"("p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS SETOF "jsonb"
    LANGUAGE "sql" STABLE
    AS $$
  SELECT
    to_jsonb(td) || jsonb_build_object('branch_name', b.name)
  FROM public.tv_displays td
  LEFT JOIN public.branches b ON td.branch_id = b.id
  WHERE td.is_registered = true;
$$;

DROP FUNCTION IF EXISTS "public"."get_or_create_tv_display"("uuid", "text");
CREATE OR REPLACE FUNCTION "public"."get_or_create_tv_display"("p_id" "uuid" DEFAULT NULL::"uuid", "p_registration_code" "text" DEFAULT NULL::"text", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("id" "uuid", "branch_id" "uuid", "registration_code" "text", "is_registered" boolean, "registered_at" timestamp with time zone, "last_heartbeat" timestamp with time zone, "media_playlist_id" "uuid", "tenant_id" "uuid", "created_at" timestamp with time zone, "updated_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  tv_record RECORD;
  generated_code TEXT;
BEGIN
  -- Priority 1: Use the provided ID if it exists
  IF p_id IS NOT NULL THEN
    SELECT * INTO tv_record FROM public.tv_displays WHERE public.tv_displays.id = p_id;
    IF FOUND THEN
      RETURN QUERY SELECT tv_record.id, tv_record.branch_id, tv_record.registration_code, tv_record.is_registered, tv_record.registered_at, tv_record.last_heartbeat, tv_record.media_playlist_id, tv_record.tenant_id, tv_record.created_at, tv_record.updated_at;
      RETURN;
    END IF;
    -- If ID is provided but not found, we will fall through to create a new record.
    -- This handles cases where localStorage has a stale ID.
  END IF;

  -- Priority 2: Use the registration code if provided
  IF p_registration_code IS NOT NULL THEN
    SELECT * INTO tv_record FROM public.tv_displays WHERE public.tv_displays.registration_code = p_registration_code;
    IF FOUND THEN
      RETURN QUERY SELECT tv_record.id, tv_record.branch_id, tv_record.registration_code, tv_record.is_registered, tv_record.registered_at, tv_record.last_heartbeat, tv_record.media_playlist_id, tv_record.tenant_id, tv_record.created_at, tv_record.updated_at;
      RETURN;
    END IF;
    -- If code is provided but not found, return nothing. Client should redirect.
    RETURN;
  END IF;

  -- Priority 3: Create a new record if no valid identifier was provided
  LOOP
    generated_code := upper(substr(md5(random()::text), 0, 7));
    IF NOT EXISTS (SELECT 1 FROM public.tv_displays WHERE public.tv_displays.registration_code = generated_code) THEN
      EXIT;
    END IF;
  END LOOP;

  INSERT INTO public.tv_displays (registration_code, is_registered)
  VALUES (generated_code, false)
  RETURNING * INTO tv_record;

  RETURN QUERY SELECT tv_record.id, tv_record.branch_id, tv_record.registration_code, tv_record.is_registered, tv_record.registered_at, tv_record.last_heartbeat, tv_record.media_playlist_id, tv_record.tenant_id, tv_record.created_at, tv_record.updated_at;
END;
$$;

DROP FUNCTION IF EXISTS "public"."get_payslip_details"("uuid");
CREATE OR REPLACE FUNCTION "public"."get_payslip_details"("p_payslip_id" "uuid", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  v_tenant_id uuid;
  v_payslip_user_id uuid;
  v_tenant_info jsonb;
  v_payslip_info jsonb;
  v_commissions jsonb;
  v_signature_info jsonb;
  v_result jsonb;
BEGIN
  -- Get tenant_id and user_id from the payslip
  SELECT tenant_id, user_id INTO v_tenant_id, v_payslip_user_id FROM public.payslips WHERE id = p_payslip_id;

  -- Get tenant info
  SELECT jsonb_build_object(
    'logo_url', logo_url,
    'name', name,
    'billing_address', billing_address,
    'tax_id', tax_id,
    'contact_phone', contact_phone
  ) INTO v_tenant_info FROM public.tenants WHERE id = v_tenant_id;

  -- Get payslip info
  SELECT to_jsonb(p.*) INTO v_payslip_info FROM public.payslips p WHERE id = p_payslip_id;

  -- Get signature info
  SELECT jsonb_build_object('google_drive_file_id', cpe.google_drive_file_id)
  INTO v_signature_info
  FROM public.commission_payment_evidences cpe
  WHERE cpe.payslip_id = p_payslip_id
  ORDER BY cpe.created_at DESC
  LIMIT 1;

  -- Get commission details
  WITH commissions_base AS (
    SELECT 
      ec.id,
      ec.created_at,
      ec.commission_amount,
      ec.sales_item_id,
      s.client_id
    FROM public.payslip_commissions pc
    JOIN public.earned_commissions ec ON pc.commission_id = ec.id
    JOIN public.sales_items si ON ec.sales_item_id = si.id
    JOIN public.sales s ON si.sale_id = s.id
    WHERE pc.payslip_id = p_payslip_id
  )
  SELECT jsonb_agg(jsonb_build_object(
    'attention_date', cb.created_at,
    'item_name', si.description,
    'item_price', si.unit_price,
    'commission_amount', cb.commission_amount,
    'client_name', c.name
  ))
  INTO v_commissions
  FROM commissions_base cb
  JOIN public.sales_items si ON cb.sales_item_id = si.id
  LEFT JOIN public.clients c ON cb.client_id = c.id;

  -- Combine all information
  v_result := jsonb_build_object(
    'tenant', v_tenant_info,
    'payslip', v_payslip_info,
    'signature', v_signature_info,
    'commissions', v_commissions
  );

  RETURN v_result;
END;
$$;

DROP FUNCTION IF EXISTS "public"."get_playlist_items"("uuid");
CREATE OR REPLACE FUNCTION "public"."get_playlist_items"("p_playlist_id" "uuid", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("id" "uuid", "playlist_id" "uuid", "media_url" "text", "media_type" "text", "item_order" integer, "created_at" timestamp with time zone, "video_title" "text", "duration_seconds" integer)
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  RETURN QUERY
  SELECT
    pi.id,
    pi.playlist_id,
    pi.media_url,
    pi.media_type,
    pi.item_order,
    pi.created_at,
    pi.video_title,
    pi.duration_seconds
  FROM public.playlist_items pi
  WHERE pi.playlist_id = p_playlist_id
  ORDER BY pi.item_order;
END;
$$;

DROP FUNCTION IF EXISTS "public"."get_purchase_reception_details"("uuid");
CREATE OR REPLACE FUNCTION "public"."get_purchase_reception_details"("p_purchase_id" "uuid", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("purchase_item_id" "uuid", "product_id" "uuid", "product_name" "text", "quantity_expected" integer, "quantity_received" integer, "cost_price" numeric)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_branch_id UUID;
BEGIN
    -- Get the branch_id from the purchase
    SELECT branch_id INTO v_branch_id FROM public.purchases WHERE id = p_purchase_id;

    RETURN QUERY
    SELECT
        pri.purchase_item_id,
        pi.product_id,
        p.name AS product_name,
        pri.quantity_expected,
        pri.quantity_received,
        bp.cost_price -- Get cost_price from branch_products
    FROM
        public.purchase_item_receptions pri
    JOIN
        public.purchase_items pi ON pri.purchase_item_id = pi.id
    JOIN
        public.products p ON pi.product_id = p.id
    LEFT JOIN
        public.branch_products bp ON pi.product_id = bp.product_id AND bp.branch_id = v_branch_id
    WHERE
        pi.purchase_id = p_purchase_id;
END;
$$;

DROP FUNCTION IF EXISTS "public"."get_tv_display_settings"("uuid");
CREATE OR REPLACE FUNCTION "public"."get_tv_display_settings"("p_tv_display_id" "uuid", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("id" "uuid", "branch_id" "uuid", "registration_code" "text", "is_registered" boolean, "registered_at" timestamp with time zone, "last_heartbeat" timestamp with time zone, "media_playlist_id" "uuid", "tenant_id" "uuid", "created_at" timestamp with time zone, "updated_at" timestamp with time zone)
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  RETURN QUERY
  SELECT *
  FROM tv_displays
  WHERE tv_displays.id = p_tv_display_id;
END;
$$;

DROP FUNCTION IF EXISTS "public"."get_vendor_commissions"("uuid");
CREATE OR REPLACE FUNCTION "public"."get_vendor_commissions"("p_user_id" "uuid", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("id" "text", "date" "text", "productname" "text", "saleamount" numeric, "commissionrate" numeric, "commissionamount" numeric)
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    -- This is a placeholder function.
    -- The actual implementation will depend on the payments table schema.
    -- For now, we return mock data.
    RETURN QUERY
    SELECT
        '1' as id,
        '2025-10-20' as date,
        'Pago de Tenant A (Plataforma X)' as productName,
        100000::numeric as saleAmount,
        50::numeric as commissionRate,
        50000::numeric as commissionAmount
    UNION ALL
    SELECT
        '2' as id,
        '2025-10-20' as date,
        'Pago de Tenant B (Plataforma Y)' as productName,
        50000::numeric as saleAmount,
        10::numeric as commissionRate,
        5000::numeric as commissionAmount;
END;
$$;

DROP FUNCTION IF EXISTS "public"."list_branch_social_networks"("uuid");
CREATE OR REPLACE FUNCTION "public"."list_branch_social_networks"("p_branch_id" "uuid", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS SETOF "public"."branch_social_networks"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    RETURN QUERY
    SELECT *
    FROM public.branch_social_networks
    WHERE branch_id = p_branch_id
    ORDER BY network;
END;
$$;

DROP FUNCTION IF EXISTS "public"."register_tv_display"("text");
CREATE OR REPLACE FUNCTION "public"."register_tv_display"("p_registration_code" "text", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS "uuid"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  v_tv_display_id uuid;
BEGIN
  INSERT INTO tv_displays (registration_code)
  VALUES (p_registration_code)
  RETURNING id INTO v_tv_display_id;

  RETURN v_tv_display_id;
END;
$$;

DROP FUNCTION IF EXISTS "public"."update_attention_items"("jsonb");
CREATE OR REPLACE FUNCTION "public"."update_attention_items"("p_payload" "jsonb", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
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
          status, is_parallel, parallel_group_id, offset_minutes, notes, tenant_id, platform_id, branch_id, client_treatment_session_id
      ) VALUES (
        COALESCE((service_item->>'id')::uuid, gen_random_uuid()), p_attention_id, (service_item->>'service_id')::uuid, (service_item->>'user_id')::uuid,
        COALESCE((service_item->>'price')::numeric, 0), (service_item->>'duration_minutes')::integer, (service_item->>'start_time')::time, (service_item->>'end_time')::time,
        service_item->>'status', (service_item->>'is_parallel')::boolean, (service_item->>'parallel_group_id')::uuid,
        (service_item->>'offset_minutes')::integer, service_item->>'notes', p_tenant_id, p_platform_id, p_branch_id, (service_item->>'client_treatment_session_id')::uuid
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
          id, attention_id, product_id, user_id, quantity, unit_price, total_price, tenant_id, platform_id, branch_id, client_treatment_session_id
      ) VALUES (
        COALESCE((product_item->>'id')::uuid, gen_random_uuid()), p_attention_id, (product_item->>'product_id')::uuid,
        (product_item->>'user_id')::uuid, (product_item->>'quantity')::integer, COALESCE((product_item->>'price')::numeric, 0),
        (COALESCE((product_item->>'quantity')::integer, 1) * COALESCE((product_item->>'price')::numeric, 0)), p_tenant_id, p_platform_id, p_branch_id, (product_item->>'client_treatment_session_id')::uuid
      ) ON CONFLICT (id) DO UPDATE SET
        product_id = EXCLUDED.product_id, user_id = EXCLUDED.user_id, quantity = EXCLUDED.quantity,
        unit_price = EXCLUDED.unit_price, total_price = EXCLUDED.total_price, client_treatment_session_id = EXCLUDED.client_treatment_session_id;
    END LOOP;
  END IF;

  -- 4. "Upsert" de combos
  IF p_combos_to_upsert IS NOT NULL THEN
    FOR combo_item IN SELECT * FROM jsonb_array_elements(p_combos_to_upsert) LOOP
      v_subtotal_check := v_subtotal_check + (COALESCE((combo_item->>'price')::numeric, 0) * COALESCE((combo_item->>'quantity')::integer, 1));
      INSERT INTO public.attention_combos (id, attention_id, combo_id, price, quantity, status, notes, tenant_id, platform_id, branch_id)
      VALUES (
        COALESCE((combo_item->>'id')::uuid, gen_random_uuid()), p_attention_id, (combo_item->>'combo_id')::uuid,
        (combo_item->>'price')::numeric, COALESCE((combo_item->>'quantity')::integer, 1),
        combo_item->>'status', combo_item->>'notes', p_tenant_id, p_platform_id, p_branch_id
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
$$;

DROP FUNCTION IF EXISTS "public"."update_attention_status"("uuid", "text");
CREATE OR REPLACE FUNCTION "public"."update_attention_status"("p_attention_id" "uuid", "p_new_status" "text", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_tenant_id uuid;
BEGIN
    -- Get the tenant_id from the attention record to ensure security context
    SELECT tenant_id INTO v_tenant_id
    FROM public.attentions
    WHERE id = p_attention_id;

    -- Optional: Add a security check to ensure the caller has rights to this tenant.
    -- This can be more complex depending on your RLS policies.
    -- For now, we assume RLS is handled or the function is called from a trusted context (like an edge function).

    -- Update the status
    UPDATE public.attentions
    SET status = p_new_status
    WHERE id = p_attention_id;

END;
$$;

DROP FUNCTION IF EXISTS "public"."update_branch_social_network"("uuid", "uuid", "public"."social_network", "text");
CREATE OR REPLACE FUNCTION "public"."update_branch_social_network"("p_id" "uuid", "p_branch_id" "uuid", "p_network" "public"."social_network", "p_url" "text", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS "public"."branch_social_networks"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    updated_record public.branch_social_networks;
BEGIN
    UPDATE public.branch_social_networks
    SET
        network = p_network,
        url = p_url,
        updated_at = now()
    WHERE id = p_id AND branch_id = p_branch_id
    RETURNING * INTO updated_record;
    RETURN updated_record;
END;
$$;

DROP FUNCTION IF EXISTS "public"."update_client_treatment_status_if_completed"("uuid");
CREATE OR REPLACE FUNCTION "public"."update_client_treatment_status_if_completed"("p_client_treatment_id" "uuid", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    UPDATE public.client_treatments ct
    SET status = 'completed'
    WHERE ct.id = p_client_treatment_id
      AND NOT EXISTS (
        SELECT 1
        FROM public.client_treatment_sessions cts
        WHERE cts.client_treatment_id = ct.id
          AND cts.status <> 'completed'
      );
END;
$$;

DROP FUNCTION IF EXISTS "public"."update_playlist_items_order"("jsonb");
CREATE OR REPLACE FUNCTION "public"."update_playlist_items_order"("items_to_update" "jsonb", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    item_data jsonb;
BEGIN
    FOR item_data IN SELECT * FROM jsonb_array_elements(items_to_update)
    LOOP
        UPDATE public.playlist_items
        SET item_order = (item_data->>'item_order')::integer
        WHERE id = (item_data->>'id')::uuid;
    END LOOP;
END;
$$;

DROP FUNCTION IF EXISTS "public"."update_purchase_payment_status"("uuid", "text");
CREATE OR REPLACE FUNCTION "public"."update_purchase_payment_status"("p_purchase_id" "uuid", "p_payment_status" "text", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    UPDATE public.purchases
    SET payment_status = p_payment_status,
        updated_at = now()
    WHERE id = p_purchase_id;
END;
$$;

DROP FUNCTION IF EXISTS "public"."update_tv_heartbeat"("uuid");
CREATE OR REPLACE FUNCTION "public"."update_tv_heartbeat"("p_tv_display_id" "uuid", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  UPDATE tv_displays
  SET
    last_heartbeat = now()
  WHERE id = p_tv_display_id;
END;
$$;

