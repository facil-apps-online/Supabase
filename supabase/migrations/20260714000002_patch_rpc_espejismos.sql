-- Parche de 29 Funciones "Espejismo" para aplicar filtro de platform_id

DROP FUNCTION IF EXISTS "public"."approve_product_transfer"("uuid", "jsonb", "uuid", "uuid", "uuid");
CREATE OR REPLACE FUNCTION "public"."approve_product_transfer"("p_transfer_id" "uuid", "p_adjusted_items" "jsonb", "p_tenant_id" "uuid", "p_user_id" "uuid", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_origin_branch_id uuid;
    item jsonb;
    v_product_id uuid;
    v_stock numeric;
    updated_transfer record;
    v_user_is_in_origin_branch boolean;
BEGIN
    -- 1. Check if the transfer exists and get its origin branch
    SELECT origin_branch_id INTO v_origin_branch_id
    FROM public.product_transfers
    WHERE id = p_transfer_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id AND status = 'solicitado';

    IF v_origin_branch_id IS NULL THEN
        RAISE EXCEPTION 'Transfer not found or not in "solicitado" state.';
    END IF;

    -- 2. Check if the user is assigned to the origin branch
    SELECT EXISTS (
        SELECT 1
        FROM auth.users u,
             jsonb_array_elements(u.raw_app_meta_data->'assignments') as assignment
        WHERE u.id = p_user_id
          AND assignment->>'branch_id' = v_origin_branch_id::text
          AND assignment->>'tenant_id' = p_tenant_id::text
    ) INTO v_user_is_in_origin_branch;

    IF NOT v_user_is_in_origin_branch THEN
        RAISE EXCEPTION 'You do not have permission to approve this transfer.';
    END IF;

    -- 3. Update quantities for each item and check stock
    FOR item IN SELECT * FROM jsonb_array_elements(p_adjusted_items)
    LOOP
        -- Get product_id for the item
        SELECT product_id INTO v_product_id
        FROM public.product_transfer_items
        WHERE id = (item->>'item_id')::uuid;

        -- Check available stock in the origin branch
        SELECT stock_quantity INTO v_stock
        FROM public.branch_products
        WHERE branch_id = v_origin_branch_id AND product_id = v_product_id;

        IF v_stock IS NULL OR v_stock < (item->>'quantity')::numeric THEN
            RAISE EXCEPTION 'Not enough stock for product ID % in origin branch.', v_product_id;
        END IF;

        -- Update the quantity in the transfer item
        UPDATE public.product_transfer_items
        SET quantity = (item->>'quantity')::integer, updated_at = now()
        WHERE id = (item->>'item_id')::uuid;
    END LOOP;

    -- 4. Update the transfer status to 'aprobado'
    UPDATE public.product_transfers
    SET status = 'aprobado', updated_at = now()
    WHERE id = p_transfer_id
    RETURNING * INTO updated_transfer;

    -- 5. Return the updated transfer
    RETURN to_jsonb(updated_transfer);
END;
$$;

DROP FUNCTION IF EXISTS "public"."cancel_product_transfer"("uuid", "uuid", "uuid", "uuid");
CREATE OR REPLACE FUNCTION "public"."cancel_product_transfer"("p_transfer_id" "uuid", "p_tenant_id" "uuid", "p_user_id" "uuid", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    updated_transfer record;
    v_transfer_status text;
    v_origin_branch_id uuid;
    v_destination_branch_id uuid;
    v_user_can_cancel boolean;
BEGIN
    -- 1. Get transfer details
    SELECT status, origin_branch_id, destination_branch_id
    INTO v_transfer_status, v_origin_branch_id, v_destination_branch_id
    FROM public.product_transfers
    WHERE id = p_transfer_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;

    IF v_transfer_status IS NULL THEN
        RAISE EXCEPTION 'Transfer not found or you do not have permission.';
    END IF;

    -- 2. Check permissions
    v_user_can_cancel := false;
    IF v_transfer_status = 'solicitado' THEN
        SELECT EXISTS (
            SELECT 1
            FROM auth.users u,
                 jsonb_array_elements(u.raw_app_meta_data->'assignments') as assignment
            WHERE u.id = p_user_id
              AND (assignment->>'branch_id' = v_origin_branch_id::text OR assignment->>'branch_id' = v_destination_branch_id::text)
              AND assignment->>'tenant_id' = p_tenant_id::text
        ) INTO v_user_can_cancel;
    ELSIF v_transfer_status = 'aprobado' THEN
        SELECT EXISTS (
            SELECT 1
            FROM auth.users u,
                 jsonb_array_elements(u.raw_app_meta_data->'assignments') as assignment
            WHERE u.id = p_user_id
              AND assignment->>'branch_id' = v_origin_branch_id::text
              AND assignment->>'tenant_id' = p_tenant_id::text
        ) INTO v_user_can_cancel;
    END IF;

    IF NOT v_user_can_cancel THEN
        RAISE EXCEPTION 'You do not have permission to cancel this transfer in its current state.';
    END IF;

    -- 3. Update the transfer status to 'cancelado'
    UPDATE public.product_transfers
    SET status = 'cancelado', updated_at = now()
    WHERE id = p_transfer_id
    RETURNING * INTO updated_transfer;

    RETURN to_jsonb(updated_transfer);
END;
$$;

DROP FUNCTION IF EXISTS "public"."create_consent_template"("uuid", "uuid", "text", "text", "jsonb");
CREATE OR REPLACE FUNCTION "public"."create_consent_template"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_name" "text", "p_content" "text" DEFAULT NULL::"text", "p_fields" "jsonb" DEFAULT NULL::"jsonb") RETURNS "public"."informed_consent_templates"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    new_template public.informed_consent_templates;
BEGIN
    INSERT INTO public.informed_consent_templates (name, content, fields, tenant_id, platform_id)
    VALUES (p_name, p_content, p_fields, p_tenant_id, p_platform_id)
    RETURNING * INTO new_template;

    RETURN new_template;
END;
$$;

DROP FUNCTION IF EXISTS "public"."create_equipment_type"("uuid", "text", "text", "uuid");
CREATE OR REPLACE FUNCTION "public"."create_equipment_type"("p_tenant_id" "uuid", "p_name" "text", "p_description" "text", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS "uuid"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    new_type_id uuid;
BEGIN
    INSERT INTO equipment_types (tenant_id, name, description)
    VALUES (p_tenant_id, p_name, p_description)
    RETURNING id INTO new_type_id;
    RETURN new_type_id;
END;
$$;

DROP FUNCTION IF EXISTS "public"."create_product_transfer_request"("uuid", "uuid", "uuid", "text", "jsonb", "uuid");
CREATE OR REPLACE FUNCTION "public"."create_product_transfer_request"("p_tenant_id" "uuid", "p_requesting_branch_id" "uuid", "p_origin_branch_id" "uuid", "p_notes" "text", "p_items" "jsonb", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    new_transfer record;
    item jsonb;
BEGIN
    -- 1. Create the product_transfers record
    INSERT INTO public.product_transfers (
        tenant_id,
        requesting_branch_id,
        origin_branch_id,
        destination_branch_id,
        status,
        notes,
        transfer_date
    )
    VALUES (
        p_tenant_id,
        p_requesting_branch_id,
        p_origin_branch_id,
        p_requesting_branch_id, -- Destination is the same as the requesting branch
        'solicitado',
        p_notes,
        now()
    )
    RETURNING * INTO new_transfer;

    -- 2. Create product_transfer_items records
    FOR item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        INSERT INTO public.product_transfer_items (
            transfer_id,
            product_id,
            quantity
        )
        VALUES (
            new_transfer.id,
            (item->>'product_id')::uuid,
            (item->>'quantity')::integer
        );
    END LOOP;

    -- 3. Return the newly created transfer
    RETURN to_jsonb(new_transfer);
END;
$$;

DROP FUNCTION IF EXISTS "public"."delete_branch_photo"("uuid", "uuid", "uuid", "uuid");
CREATE OR REPLACE FUNCTION "public"."delete_branch_photo"("p_branch_id" "uuid", "p_photo_id" "uuid", "p_tenant_id" "uuid", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_google_drive_file_id text;
    v_is_primary boolean;
BEGIN
    -- Check if the photo exists, belongs to the tenant/branch, and get its details
    SELECT google_drive_file_id, is_primary
    INTO v_google_drive_file_id, v_is_primary
    FROM public.branch_photos
    WHERE id = p_photo_id AND branch_id = p_branch_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;

    IF v_google_drive_file_id IS NULL THEN
        RAISE EXCEPTION 'Photo not found or permission denied';
    END IF;

    -- If it's the primary photo, check if there are other photos for the branch.
    -- If there are, we might need to automatically set a new primary, or prevent deletion.
    -- Correction: If it's the primary photo AND there are other photos, prevent deletion.
    IF v_is_primary AND (SELECT COUNT(*) FROM public.branch_photos WHERE branch_id = p_branch_id AND id != p_photo_id) > 0 THEN
        RAISE EXCEPTION 'Cannot delete primary photo if other photos exist. Set another photo as primary first.';
    END IF;


    -- Delete the record from the database
    DELETE FROM public.branch_photos
    WHERE id = p_photo_id;

    -- Return the Google Drive File ID so the edge function can delete the file from Drive
    RETURN v_google_drive_file_id;
END;
$$;

DROP FUNCTION IF EXISTS "public"."delete_equipment_type"("uuid", "uuid", "uuid");
CREATE OR REPLACE FUNCTION "public"."delete_equipment_type"("p_tenant_id" "uuid", "p_type_id" "uuid", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    -- Check if the type is being used by any equipment
    IF EXISTS (SELECT 1 FROM equipment WHERE type_id = p_type_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id) THEN
        RAISE EXCEPTION 'Cannot delete equipment type because it is in use.';
    END IF;

    DELETE FROM equipment_types WHERE id = p_type_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;
END;
$$;

DROP FUNCTION IF EXISTS "public"."get_equipment"("uuid", "uuid", "uuid", "uuid");
CREATE OR REPLACE FUNCTION "public"."get_equipment"("p_tenant_id" "uuid", "p_branch_id" "uuid" DEFAULT NULL::"uuid", "p_user_id" "uuid" DEFAULT NULL::"uuid", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("id" "uuid", "name" "text", "type_name" "text", "brand" "text", "model" "text", "serial_number" "text", "assigned_user_name" "text", "branch_name" "text")
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        e.id,
        e.name,
        et.name as type_name,
        e.brand,
        e.model,
        e.serial_number,
        u.first_name || ' ' || u.last_name as assigned_user_name,
        b.name as branch_name
    FROM
        equipment e
    LEFT JOIN
        equipment_types et ON e.type_id = et.id
    LEFT JOIN
        equipment_assignments ea ON e.id = ea.equipment_id AND ea.return_date IS NULL
    LEFT JOIN
        users u ON ea.user_id = u.id
    LEFT JOIN
        branches b ON ea.branch_id = b.id
    WHERE
        e.tenant_id = p_tenant_id AND e.platform_id = p_platform_id
        AND (p_branch_id IS NULL OR ea.branch_id = p_branch_id)
        AND (p_user_id IS NULL OR ea.user_id = p_user_id);
END;
$$;

DROP FUNCTION IF EXISTS "public"."get_equipment_types"("uuid", "uuid");
CREATE OR REPLACE FUNCTION "public"."get_equipment_types"("p_tenant_id" "uuid", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("id" "uuid", "name" "text", "description" "text", "is_active" boolean)
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY
    SELECT et.id, et.name, et.description, et.is_active
    FROM equipment_types et
    WHERE et.tenant_id = p_tenant_id
    ORDER BY et.name;
END;
$$;

DROP FUNCTION IF EXISTS "public"."get_gmail_auth_url"("uuid", "uuid");
CREATE OR REPLACE FUNCTION "public"."get_gmail_auth_url"("p_tenant_id" "uuid", "p_platform_id" "uuid") RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN 'https://accounts.google.com/o/oauth2/v2/auth...'; -- Placeholder logic
END;
$$;

DROP FUNCTION IF EXISTS "public"."get_google_auth_url"("uuid", "uuid");
CREATE OR REPLACE FUNCTION "public"."get_google_auth_url"("p_tenant_id" "uuid", "p_platform_id" "uuid") RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    -- Esta función suele ser un placeholder para lógica que se resuelve en la Edge,
    -- pero la estandarizamos para que el filtro sea correcto si busca config.
    RETURN 'https://accounts.google.com/o/oauth2/v2/auth...'; -- Placeholder logic
END;
$$;

DROP FUNCTION IF EXISTS "public"."get_price_for_tenant_asset"("uuid", "uuid", "text");
CREATE OR REPLACE FUNCTION "public"."get_price_for_tenant_asset"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_asset_key" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    -- Lógica de consulta a Core o localmente
    RETURN '{}'::jsonb;
END;
$$;

DROP FUNCTION IF EXISTS "public"."get_tenant_activity_summary"("uuid", "uuid");
CREATE OR REPLACE FUNCTION "public"."get_tenant_activity_summary"("p_tenant_id" "uuid", "p_platform_id" "uuid") RETURNS TABLE("tenant_id" "uuid", "tenant_name" "text", "total_users" bigint, "total_clients" bigint, "total_appointments" bigint, "total_services" bigint, "total_products" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    IF NOT public.is_super_admin() THEN
        RAISE EXCEPTION 'Acceso denegado. Solo los superadministradores pueden ver el resumen de actividad de los tenants.';
    END IF;

    RETURN QUERY
    SELECT
        t.id AS tenant_id,
        t.name AS tenant_name,
        (SELECT COUNT(DISTINCT u.id) FROM auth.users u JOIN public.user_assignments ua ON u.id = ua.user_id WHERE ua.tenant_id = t.id) AS total_users,
        (SELECT COUNT(*) FROM public.clients c WHERE c.tenant_id = t.id) AS total_clients,
        (SELECT COUNT(*) FROM public.attentions a WHERE a.tenant_id = t.id) AS total_appointments,
        (SELECT COUNT(*) FROM public.services s WHERE s.tenant_id = t.id) AS total_services,
        (SELECT COUNT(*) FROM public.products p WHERE p.tenant_id = t.id) AS total_products
    FROM
        public.tenants t
    WHERE t.id = p_tenant_id;
END;
$$;

DROP FUNCTION IF EXISTS "public"."get_tenant_settings_data"("uuid", "uuid");
CREATE OR REPLACE FUNCTION "public"."get_tenant_settings_data"("tenant_id_param" "uuid", "p_platform_id" "uuid") RETURNS json
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  RETURN json_build_object(
    'tenant', (
      SELECT json_build_object(
        'id', t.id,
        'name', t.name,
        'logo_url', t.logo_url,
        'slug', t.slug,
        'description', t.description, -- Added
        'country_id', t.country_id,
        'default_language_code', t.default_language_code,
        'default_currency_id', t.default_currency_id,
        'default_timezone', t.default_timezone,
        'contact_phone', t.contact_phone,
        'whatsapp_phone', t.whatsapp_phone,
        'commercial_email', t.commercial_email,
        'legal_name', t.legal_name,
        'tax_id', t.tax_id,
        'billing_address', t.billing_address,
        'einvoicing_email', t.einvoicing_email,
        'physical_address_line1', t.physical_address_line1,
        'physical_address_line2', t.physical_address_line2,
        'physical_city', t.physical_city,
        'physical_state', t.physical_state,
        'physical_postal_code', t.physical_postal_code,
        'website', t.website,
        'latitude', t.latitude,
        'longitude', t.longitude
      )
      FROM tenants t
      WHERE t.id = tenant_id_param
    ),
    'countries', (
      SELECT json_agg(
        json_build_object(
          'id', c.id,
          'name', c.name,
          'iso_code', c.iso_code,
          'is_active', c.is_active,
          'default_localization_id', c.default_localization_id,
          'default_currency_id', c.default_currency_id,
          'timezones', (
            SELECT json_agg(tz.name)
            FROM public.country_timezones ct
            JOIN public.timezones tz ON ct.timezone_id = tz.id
            WHERE ct.country_id = c.id
          )
        )
      )
      FROM countries c
      WHERE c.is_active = true
    ),
    'languages', (
      SELECT json_agg(
        json_build_object(
          'id', l.id,
          'name', l.name,
          'iso_code', l.iso_code
        )
      )
      FROM languages l
      WHERE l.is_active = true
    ),
    'currencies', (
      SELECT json_agg(
        json_build_object(
          'id', curr.id,
          'name', curr.name,
          'symbol', curr.symbol,
          'code', curr.code,
          'decimal_places', curr.decimal_places,
          'symbol_position', curr.symbol_position,
          'decimal_separator', curr.decimal_separator,
          'thousands_separator', curr.thousands_separator
        )
      )
      FROM currencies curr
      WHERE curr.is_active = true
    )
  );
END;
$$;

DROP FUNCTION IF EXISTS "public"."get_transfer_details"("uuid", "uuid", "uuid");
CREATE OR REPLACE FUNCTION "public"."get_transfer_details"("p_transfer_id" "uuid", "p_tenant_id" "uuid", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("item_id" "uuid", "product_id" "uuid", "product_name" "text", "quantity" numeric, "allow_decimal_sale" boolean)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        pti.id as item_id,
        pti.product_id,
        p.name as product_name,
        pti.quantity,
        p.allow_decimal_sale -- Añadido el nuevo campo
    FROM
        public.product_transfer_items pti
    JOIN
        public.products p ON pti.product_id = p.id
    JOIN
        public.product_transfers pt ON pti.transfer_id = pt.id
    WHERE
        pti.transfer_id = p_transfer_id
        AND pt.tenant_id = p_tenant_id;
END;
$$;

DROP FUNCTION IF EXISTS "public"."increment_asset_usage_rpc"("uuid", "uuid", "text", "p_quantity_to_add" bigint);
CREATE OR REPLACE FUNCTION "public"."increment_asset_usage_rpc"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_asset_key" "text", "p_quantity_to_add" bigint) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    -- Nota: asset_usage_tracking suele estar en Core, pero si existe localmente:
    -- Ajustar si la tabla existe en Servicios
    NULL;
END;
$$;

DROP FUNCTION IF EXISTS "public"."log_audit_action"("text", "uuid", "text", "uuid", "jsonb", "jsonb", "inet", "text", "jsonb", "uuid", "uuid", "uuid");
CREATE OR REPLACE FUNCTION "public"."log_audit_action"("p_action" "text", "p_user_id" "uuid", "p_object_type" "text" DEFAULT NULL::"text", "p_object_id" "uuid" DEFAULT NULL::"uuid", "p_old_value" "jsonb" DEFAULT NULL::"jsonb", "p_new_value" "jsonb" DEFAULT NULL::"jsonb", "p_ip_address" "inet" DEFAULT NULL::"inet", "p_user_agent" "text" DEFAULT NULL::"text", "p_metadata" "jsonb" DEFAULT NULL::"jsonb", "p_tenant_id" "uuid" DEFAULT NULL::"uuid", "p_platform_id" "uuid" DEFAULT NULL::"uuid", "p_branch_id" "uuid" DEFAULT NULL::"uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    INSERT INTO public.audit_logs (user_id, tenant_id, platform_id, branch_id, action, object_type, object_id, old_value, new_value, ip_address, user_agent, metadata)
    VALUES (p_user_id, p_tenant_id, p_platform_id, p_branch_id, p_action, p_object_type, p_object_id, p_old_value, p_new_value, p_ip_address, p_user_agent, p_metadata);
END;
$$;

DROP FUNCTION IF EXISTS "public"."reject_product_transfer"("uuid", "uuid", "uuid", "uuid");
CREATE OR REPLACE FUNCTION "public"."reject_product_transfer"("p_transfer_id" "uuid", "p_tenant_id" "uuid", "p_user_id" "uuid", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    updated_transfer record;
    v_origin_branch_id uuid;
    v_user_is_in_origin_branch boolean;
BEGIN
    -- 1. Check if the transfer exists and get its origin branch
    SELECT origin_branch_id INTO v_origin_branch_id
    FROM public.product_transfers
    WHERE id = p_transfer_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id AND status = 'solicitado';

    IF v_origin_branch_id IS NULL THEN
        RAISE EXCEPTION 'Transfer not found, not in "solicitado" state, or you do not have permission.';
    END IF;

    -- 2. Check if the user is assigned to the origin branch
    SELECT EXISTS (
        SELECT 1
        FROM auth.users u,
             jsonb_array_elements(u.raw_app_meta_data->'assignments') as assignment
        WHERE u.id = p_user_id
          AND assignment->>'branch_id' = v_origin_branch_id::text
          AND assignment->>'tenant_id' = p_tenant_id::text
    ) INTO v_user_is_in_origin_branch;

    IF NOT v_user_is_in_origin_branch THEN
        RAISE EXCEPTION 'You do not have permission to reject this transfer.';
    END IF;

    -- 3. Update the transfer status to 'rechazado'
    UPDATE public.product_transfers
    SET status = 'rechazado', updated_at = now()
    WHERE id = p_transfer_id
    RETURNING * INTO updated_transfer;

    RETURN to_jsonb(updated_transfer);
END;
$$;

DROP FUNCTION IF EXISTS "public"."search_clients"("uuid", "uuid", "text", "text", "p_show_inactive" boolean);
CREATE OR REPLACE FUNCTION "public"."search_clients"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_branch_id" "text", "p_search_term" "text", "p_show_inactive" boolean) RETURNS TABLE("id" "uuid", "name" "text", "email" "text", "phone" "text", "document_type_id" "uuid", "document_number" "text", "is_active" boolean, "parent_client_id" "uuid", "tenant_id" "uuid", "platform_id" "uuid", "created_at" timestamp with time zone, "updated_at" timestamp with time zone, "parent_client_name" "text", "branches" "jsonb")
    LANGUAGE "plpgsql"
    AS $_$
DECLARE
    search_words TEXT[];
    filtered_words TEXT[];
    search_query TEXT;
    final_query TEXT;
    branch_uuid UUID;
    word TEXT;
BEGIN
    -- Handle 'all' branches case
    IF p_branch_id = 'all' THEN
        branch_uuid := NULL;
    ELSE
        branch_uuid := p_branch_id::UUID;
    END IF;

    -- Build the full-text search query
    IF p_search_term IS NOT NULL AND p_search_term <> '' THEN
        search_words := string_to_array(lower(p_search_term), ' ');
        
        -- Filter out empty strings
        FOREACH word IN ARRAY search_words
        LOOP
            IF word <> '' THEN
                filtered_words := array_append(filtered_words, word || ':*');
            END IF;
        END LOOP;

        IF array_length(filtered_words, 1) > 0 THEN
            search_query := array_to_string(filtered_words, ' & ');
        ELSE
            search_query := NULL;
        END IF;
    ELSE
        search_query := NULL;
    END IF;

    -- Construct the final query
    final_query := '
        WITH client_branches_agg AS (
            SELECT 
                cb.client_id, 
                jsonb_agg(jsonb_build_object(''id'', b.id, ''name'', b.name)) as branches
            FROM client_branches cb
            JOIN branches b ON cb.branch_id = b.id AND cb.tenant_id = b.tenant_id AND cb.platform_id = b.platform_id
            WHERE cb.tenant_id = $1 AND cb.platform_id = $3
            GROUP BY cb.client_id
        )
        SELECT
            c.id,
            c.name,
            c.email,
            c.phone,
            c.document_type_id,
            c.document_number,
            c.is_active,
            c.parent_client_id,
            c.tenant_id,
            c.platform_id,
            c.created_at,
            c.updated_at,
            pc.name as parent_client_name,
            cba.branches
        FROM
            clients c
        LEFT JOIN
            clients pc ON c.parent_client_id = pc.id AND c.tenant_id = pc.tenant_id AND c.platform_id = pc.platform_id
        LEFT JOIN 
            client_branches_agg cba ON c.id = cba.client_id
        WHERE
            c.tenant_id = $1 AND c.platform_id = $3';

    IF branch_uuid IS NOT NULL THEN
        final_query := final_query || '
            AND c.id IN (SELECT client_id FROM client_branches WHERE branch_id = $2 AND tenant_id = $1 AND platform_id = $3)';
    END IF;

    IF NOT p_show_inactive THEN
        final_query := final_query || '
            AND c.is_active = TRUE';
    END IF;

    IF search_query IS NOT NULL THEN
        final_query := final_query || format(' AND c.fts @@ to_tsquery(''simple'', %L)', search_query);
    END IF;

    final_query := final_query || '
        ORDER BY c.name;';

    -- Execute the query
    IF branch_uuid IS NOT NULL THEN
         RETURN QUERY EXECUTE final_query USING p_tenant_id, branch_uuid, p_platform_id;
    ELSE
         RETURN QUERY EXECUTE final_query USING p_tenant_id, NULL, p_platform_id;
    END IF;

END;
$_$;


ALTER FUNCTION "public"."search_clients"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_branch_id" "text", "p_search_term" "text", "p_show_inactive" boolean) OWNER TO "postgres";






DROP FUNCTION IF EXISTS "public"."search_products"("uuid", "uuid", "text", "p_show_inactive" boolean, "text", "uuid");
CREATE OR REPLACE FUNCTION "public"."search_products"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_search_term" "text" DEFAULT NULL::"text", "p_show_inactive" boolean DEFAULT false, "p_category_name" "text" DEFAULT NULL::"text", "p_brand_id" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("id" "uuid", "name" "text", "description" "text", "is_active" boolean, "category" "text", "created_at" timestamp with time zone, "updated_at" timestamp with time zone, "cost_price" numeric, "last_purchase_cost" numeric, "average_cost" numeric, "brand_id" "uuid", "barcode" "text", "sku" "text", "tenant_id" "uuid", "name_i18n" "jsonb", "description_i18n" "jsonb", "unit_of_measure_id" "uuid", "package_content_quantity" numeric, "allow_decimal_sale" boolean)
    LANGUAGE "plpgsql"
    AS $_$
DECLARE
    search_words TEXT[];
    word TEXT;
    query_conditions TEXT[] := ARRAY[]::TEXT[];
    final_query TEXT;
BEGIN
    -- Split the search term into words
    IF p_search_term IS NOT NULL AND p_search_term <> '' THEN
        search_words := string_to_array(lower(p_search_term), ' ');
    ELSE
        search_words := ARRAY[]::TEXT[];
    END IF;

    -- Build the query conditions for each word
    FOREACH word IN ARRAY search_words
    LOOP
        IF word <> '' THEN
            query_conditions := array_append(
                query_conditions,
                format(
                    '(p.name ILIKE %1$L OR p.description ILIKE %1$L OR p.sku ILIKE %1$L OR p.barcode ILIKE %1$L)',
                    '%' || word || '%'
                )
            );
        END IF;
    END LOOP;

    -- Construct the final query
    final_query := '
        SELECT
            p.id,
            p.name,
            p.description,
            p.is_active,
            p.category,
            p.created_at,
            p.updated_at,
            p.cost_price,
            p.last_purchase_cost,
            p.average_cost,
            p.brand_id,
            p.barcode,
            p.sku,
            p.tenant_id,
            p.name_i18n,
            p.description_i18n,
            p.unit_of_measure_id,      -- Campo añadido
            p.package_content_quantity, -- Campo añadido
            p.allow_decimal_sale       -- Campo añadido
        FROM
            products p
        WHERE
            p.tenant_id = $1';

    IF NOT p_show_inactive THEN
        final_query := final_query || '
            AND p.is_active = TRUE';
    END IF;

    IF p_category_name IS NOT NULL AND p_category_name <> '' THEN
        final_query := final_query || format('
            AND p.category = %L', p_category_name);
    END IF;

    IF p_brand_id IS NOT NULL THEN
        final_query := final_query || format('
            AND p.brand_id = %L', p_brand_id);
    END IF;

    IF array_length(query_conditions, 1) > 0 THEN
        final_query := final_query || '
            AND (' || array_to_string(query_conditions, ' AND ') || ')';
    END IF;

    final_query := final_query || '
        ORDER BY p.name;';

    -- Execute the query
    RETURN QUERY EXECUTE final_query USING p_tenant_id;
END;
$_$;


ALTER FUNCTION "public"."search_products"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_search_term" "text", "p_show_inactive" boolean, "p_category_name" "text", "p_brand_id" "uuid") OWNER TO "postgres";






DROP FUNCTION IF EXISTS "public"."search_products"("uuid", "uuid", "text", "p_show_inactive" boolean, "uuid", "uuid");
CREATE OR REPLACE FUNCTION "public"."search_products"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_search_term" "text", "p_show_inactive" boolean, "p_category_id" "uuid", "p_brand_id" "uuid") RETURNS TABLE("id" "uuid", "name" "text", "description" "text", "is_active" boolean, "created_at" timestamp with time zone, "updated_at" timestamp with time zone, "cost_price" numeric, "last_purchase_cost" numeric, "average_cost" numeric, "brand_id" "uuid", "barcode" "text", "sku" "text", "tenant_id" "uuid", "platform_id" "uuid", "name_i18n" "jsonb", "description_i18n" "jsonb", "unit_of_measure_id" "uuid", "package_content_quantity" numeric, "allow_decimal_sale" boolean, "product_images" "jsonb", "product_categories" "jsonb")
    LANGUAGE "plpgsql"
    AS $_$
DECLARE
    search_words TEXT[];
    word TEXT;
    query_conditions TEXT[] := ARRAY[]::TEXT[];
    final_query TEXT;
BEGIN
    IF p_search_term IS NOT NULL AND p_search_term <> '' THEN
        search_words := string_to_array(lower(p_search_term), ' ');
    ELSE
        search_words := ARRAY[]::TEXT[];
    END IF;

    FOREACH word IN ARRAY search_words
    LOOP
        IF word <> '' THEN
            query_conditions := array_append(
                query_conditions,
                format(
                    '(p.name ILIKE %1$L OR p.description ILIKE %1$L OR p.sku ILIKE %1$L OR p.barcode ILIKE %1$L)',
                    '%' || word || '%'
                )
            );
        END IF;
    END LOOP;

    final_query := '
        SELECT
            p.id,
            p.name,
            p.description,
            p.is_active,
            p.created_at,
            p.updated_at,
            p.cost_price,
            p.last_purchase_cost,
            p.average_cost,
            p.brand_id,
            p.barcode,
            p.sku,
            p.tenant_id,
            p.platform_id,
            p.name_i18n,
            p.description_i18n,
            p.unit_of_measure_id,
            p.package_content_quantity,
            p.allow_decimal_sale,
            COALESCE(pi.images, ''[]''::jsonb) AS product_images,
            COALESCE(pc.categories, ''[]''::jsonb) as product_categories
        FROM
            public.products p
        LEFT JOIN (
            SELECT
                product_id,
                jsonb_agg(jsonb_build_object(
                    ''id'', id,
                    ''image_url'', image_url,
                    ''sort_order'', sort_order,
                    ''is_primary'', is_primary
                ) ORDER BY is_primary DESC, sort_order ASC) AS images
            FROM
                public.product_images
            WHERE tenant_id = $1 AND platform_id = $2
            GROUP BY
                product_id
        ) pi ON p.id = pi.product_id
        LEFT JOIN (
            SELECT
                pca.product_id,
                jsonb_agg(jsonb_build_object(''id'', pc.id, ''name'', pc.name) ORDER BY pc.name) AS categories
            FROM
                public.product_category_assignments pca
            JOIN
                public.product_categories pc ON pca.category_id = pc.id AND pca.tenant_id = pc.tenant_id AND pca.platform_id = pc.platform_id
            WHERE pca.tenant_id = $1 AND pca.platform_id = $2
            GROUP BY
                pca.product_id
        ) pc ON p.id = pc.product_id
        WHERE
            p.tenant_id = $1 AND p.platform_id = $2';

    IF NOT p_show_inactive THEN
        final_query := final_query || '
            AND p.is_active = TRUE';
    END IF;

    IF p_category_id IS NOT NULL THEN
        final_query := final_query || format('
            AND p.id IN (SELECT product_id FROM public.product_category_assignments WHERE category_id = %L AND tenant_id = %L AND platform_id = %L)', p_category_id, p_tenant_id, p_platform_id);
    END IF;

    IF p_brand_id IS NOT NULL THEN
        final_query := final_query || format('
            AND p.brand_id = %L', p_brand_id);
    END IF;

    IF array_length(query_conditions, 1) > 0 THEN
        final_query := final_query || '
            AND (' || array_to_string(query_conditions, ' AND ') || ')';
    END IF;

    final_query := final_query || '
        ORDER BY p.name;';

    RETURN QUERY EXECUTE final_query USING p_tenant_id, p_platform_id;
END;
$_$;


ALTER FUNCTION "public"."search_products"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_search_term" "text", "p_show_inactive" boolean, "p_category_id" "uuid", "p_brand_id" "uuid") OWNER TO "postgres";






DROP FUNCTION IF EXISTS "public"."set_primary_branch_photo"("uuid", "uuid", "uuid", "uuid");
CREATE OR REPLACE FUNCTION "public"."set_primary_branch_photo"("p_tenant_id" "uuid", "p_branch_id" "uuid", "p_photo_id" "uuid", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    -- First, ensure the photo belongs to the tenant and branch
    IF NOT EXISTS (
        SELECT 1 FROM public.branch_photos
        WHERE id = p_photo_id AND branch_id = p_branch_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id
    ) THEN
        RAISE EXCEPTION 'Photo not found or permission denied';
    END IF;

    -- Set all other photos for this branch to not be primary
    UPDATE public.branch_photos
    SET is_primary = false
    WHERE branch_id = p_branch_id
      AND tenant_id = p_tenant_id AND platform_id = p_platform_id
      AND is_primary = true;

    -- Set the specified photo as primary
    UPDATE public.branch_photos
    SET is_primary = true,
        updated_at = now()
    WHERE id = p_photo_id;
END;
$$;

DROP FUNCTION IF EXISTS "public"."set_user_assignment"("uuid", "uuid", "uuid", "uuid", "uuid", "text");
CREATE OR REPLACE FUNCTION "public"."set_user_assignment"("p_target_user_id" "uuid", "p_tenant_id" "uuid", "p_platform_id" "uuid", "p_role_id" "uuid", "p_branch_id" "uuid" DEFAULT NULL::"uuid", "p_status" "text" DEFAULT 'active'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_caller_id UUID := auth.uid();
    v_caller_role TEXT := (auth.jwt() -> 'app_metadata' ->> 'role');
    v_caller_tenant_id UUID := (auth.jwt() -> 'app_metadata' ->> 'tenant_id')::uuid;
    
    v_target_role_name TEXT;
    v_new_metadata JSONB;
BEGIN
    -- Step 1: Validate that the target role exists
    SELECT name INTO v_target_role_name FROM public.roles WHERE id = p_role_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Role with ID % not found.', p_role_id;
    END IF;

    -- Step 2: Authorization Check (Who is calling this function?)
    IF v_caller_role = 'super_admin' THEN
        -- Super admin can do anything.
        NULL; 
    ELSIF v_caller_role = 'tenant_super_admin' THEN
        -- Tenant super admin can only make assignments within their own tenant.
        IF p_tenant_id != v_caller_tenant_id THEN
            RAISE EXCEPTION 'Permission denied: You can only assign users within your own tenant.';
        END IF;
        -- And they cannot create another super admin.
        IF v_target_role_name = 'super_admin' THEN
            RAISE EXCEPTION 'Permission denied: You cannot assign the super_admin role.';
        END IF;
    ELSE
        -- All other roles are denied.
        RAISE EXCEPTION 'Permission denied: You do not have rights to assign roles.';
    END IF;

    -- Step 3: Construct the new metadata object
    v_new_metadata := jsonb_build_object(
        'role', v_target_role_name,
        'tenant_id', p_tenant_id,
        'branch_id', p_branch_id,
        'assignment_status', p_status
    );

    -- Step 4: Update the user's app_metadata in the auth.users table
    UPDATE auth.users
    SET raw_app_meta_data = raw_app_meta_data || v_new_metadata
    WHERE id = p_target_user_id;

    -- Step 5: Return success
    RETURN jsonb_build_object('success', true, 'message', 'User assignment updated successfully.');

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$;

DROP FUNCTION IF EXISTS "public"."ship_product_transfer"("uuid", "uuid", "uuid", "uuid");
CREATE OR REPLACE FUNCTION "public"."ship_product_transfer"("p_transfer_id" "uuid", "p_tenant_id" "uuid", "p_user_id" "uuid", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_transfer record;
    item record;
    v_user_is_in_origin_branch boolean;
BEGIN
    -- 1. Find the approved transfer for the current tenant
    SELECT * INTO v_transfer
    FROM public.product_transfers
    WHERE id = p_transfer_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id AND status = 'aprobado';

    IF v_transfer IS NULL THEN
        RAISE EXCEPTION 'Approved transfer not found.';
    END IF;

    -- 2. Check if the user is assigned to the origin branch
    SELECT EXISTS (
        SELECT 1
        FROM auth.users u,
             jsonb_array_elements(u.raw_app_meta_data->'assignments') as assignment
        WHERE u.id = p_user_id
          AND assignment->>'branch_id' = v_transfer.origin_branch_id::text
          AND assignment->>'tenant_id' = p_tenant_id::text
    ) INTO v_user_is_in_origin_branch;

    IF NOT v_user_is_in_origin_branch THEN
        RAISE EXCEPTION 'You do not have permission to ship this transfer.';
    END IF;

    -- 3. Deduct stock from the origin branch for each item in the transfer
    FOR item IN
        SELECT pti.product_id, pti.quantity
        FROM public.product_transfer_items pti
        WHERE pti.transfer_id = v_transfer.id
    LOOP
        UPDATE public.branch_products
        SET stock_quantity = stock_quantity - item.quantity
        WHERE branch_id = v_transfer.origin_branch_id AND product_id = item.product_id;
    END LOOP;

    -- 4. Update the transfer status to 'en_transito'
    UPDATE public.product_transfers
    SET status = 'en_transito', updated_at = now()
    WHERE id = p_transfer_id
    RETURNING * INTO v_transfer;

    -- 5. Return the updated transfer
    RETURN to_jsonb(v_transfer);
END;
$$;

DROP FUNCTION IF EXISTS "public"."trigger_test_email_for_tenant"("uuid", "uuid");
CREATE OR REPLACE FUNCTION "public"."trigger_test_email_for_tenant"("p_tenant_id" "uuid", "p_platform_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_super_admin_user RECORD;
    v_full_name TEXT;
BEGIN
    -- Encontrar al super_admin del sistema
    SELECT u.id, (u.raw_user_meta_data->>'first_name') as first_name, (u.raw_user_meta_data->>'last_name') as last_name
    INTO v_super_admin_user
    FROM auth.users u, jsonb_array_elements(u.raw_app_meta_data -> 'assignments') AS assignment
    WHERE (assignment ->> 'role') = 'super_admin'
    LIMIT 1;

    IF v_super_admin_user.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'No se encontró al usuario super_admin del sistema.');
    END IF;

    -- Construir el nombre completo
    v_full_name := TRIM(COALESCE(v_super_admin_user.first_name, '') || ' ' || COALESCE(v_super_admin_user.last_name, ''));
    IF v_full_name = '' THEN
        v_full_name := 'Super Administrador';
    END IF;

    -- Llamar a la función principal de envío de correos
    PERFORM public.trigger_system_email(
        p_recipient_user_id := v_super_admin_user.id,
        p_template_type := 'WELCOME_USER',
        p_template_data := jsonb_build_object('user_name', v_full_name)
    );

    RETURN jsonb_build_object('success', true, 'message', 'El correo de prueba ha sido puesto en la cola de envío.');

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error inesperado: ' || SQLERRM);
END;
$$;

DROP FUNCTION IF EXISTS "public"."update_equipment_type"("uuid", "uuid", "text", "text", "p_is_active" boolean, "uuid");
CREATE OR REPLACE FUNCTION "public"."update_equipment_type"("p_tenant_id" "uuid", "p_type_id" "uuid", "p_name" "text", "p_description" "text", "p_is_active" boolean, "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    UPDATE equipment_types
    SET
        name = p_name,
        description = p_description,
        is_active = p_is_active,
        updated_at = now()
    WHERE id = p_type_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;
END;
$$;

DROP FUNCTION IF EXISTS "public"."update_tenant_description"("uuid", "uuid", "text");
CREATE OR REPLACE FUNCTION "public"."update_tenant_description"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_description" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    UPDATE public.tenants
    SET
        description = p_description,
        updated_at = now()
    WHERE id = p_tenant_id AND platform_id = p_platform_id;
END;
$$;

DROP FUNCTION IF EXISTS "public"."update_tenant_slug"("uuid", "uuid", "text");
CREATE OR REPLACE FUNCTION "public"."update_tenant_slug"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_slug" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $_$
DECLARE
    v_country_id uuid;
    v_platform_id uuid;
BEGIN
    -- Get the tenant's country and platform
    SELECT country_id, platform_id INTO v_country_id, v_platform_id FROM public.tenants WHERE id = p_tenant_id AND platform_id = p_platform_id AND platform_id = p_platform_id;

    IF v_platform_id IS NULL OR v_country_id IS NULL THEN
        RAISE EXCEPTION 'Could not determine platform or country for tenant';
    END IF;

    -- Check for slug format
    IF p_slug IS NOT NULL AND (p_slug !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$' OR length(p_slug) <= 2) THEN
        RAISE EXCEPTION 'invalid_slug_format';
    END IF;

    -- Check for uniqueness within the platform and country
    IF p_slug IS NOT NULL AND EXISTS (
        SELECT 1
        FROM public.tenants
        WHERE platform_id = v_platform_id
          AND country_id = v_country_id
          AND slug = p_slug
          AND id != p_tenant_id
    ) THEN
        RAISE EXCEPTION 'slug_already_taken';
    END IF;

    -- Update the tenant's slug
    UPDATE public.tenants
    SET slug = p_slug,
        updated_at = now()
    WHERE id = p_tenant_id;
END;
$_$;


ALTER FUNCTION "public"."update_tenant_slug"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_slug" "text") OWNER TO "postgres";






DROP FUNCTION IF EXISTS "public"."update_user_assignment_status"("uuid", "uuid", "uuid", "text");
CREATE OR REPLACE FUNCTION "public"."update_user_assignment_status"("p_target_user_id" "uuid", "p_tenant_id" "uuid", "p_platform_id" "uuid", "p_new_status" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_caller_role TEXT := (auth.jwt() -> 'app_metadata' ->> 'role');
    v_caller_tenant_id UUID := (auth.jwt() -> 'app_metadata' ->> 'tenant_id')::uuid;
    v_current_metadata JSONB;
    v_new_metadata JSONB;
BEGIN
    -- Step 2a: Authorization Check
    IF v_caller_role NOT IN ('super_admin', 'tenant_super_admin', 'tenant_admin') THEN
        RAISE EXCEPTION 'Permission denied: You do not have rights to update user status.';
    END IF;

    IF v_caller_role != 'super_admin' AND v_caller_tenant_id != p_tenant_id THEN
        RAISE EXCEPTION 'Permission denied: You can only update users within your own tenant.';
    END IF;

    -- Step 2b: Get the current metadata of the target user
    SELECT raw_app_meta_data INTO v_current_metadata FROM auth.users WHERE id = p_target_user_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Target user not found.';
    END IF;

    -- Step 2c: Construct the new metadata object by updating the status
    v_new_metadata := v_current_metadata || jsonb_build_object('assignment_status', p_new_status);

    -- Step 2d: Update the user's app_metadata
    UPDATE auth.users
    SET raw_app_meta_data = v_new_metadata
    WHERE id = p_target_user_id;

    -- Step 2e: Return success
    RETURN jsonb_build_object('success', true, 'message', 'User assignment status updated successfully.');

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$;

