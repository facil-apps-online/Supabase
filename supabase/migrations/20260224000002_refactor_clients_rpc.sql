-- Migración: Refactorización de funciones RPC del módulo de Clientes, Tratamientos y Consentimientos
-- Se agrega el parámetro p_platform_id y se estandarizan los filtros por tenant_id y platform_id.
-- Timestamp: 20260224000002

BEGIN;

--------------------------------------------------------------------------------
-- 1. search_clients
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.search_clients(uuid, text, text, boolean);
CREATE OR REPLACE FUNCTION public.search_clients(
    p_tenant_id uuid, 
    p_platform_id uuid,
    p_branch_id text, 
    p_search_term text, 
    p_show_inactive boolean
)
 RETURNS TABLE(
    id uuid, 
    name text, 
    email text, 
    phone text, 
    document_type_id uuid, 
    document_number text, 
    is_active boolean, 
    parent_client_id uuid, 
    tenant_id uuid, 
    platform_id uuid,
    created_at timestamp with time zone, 
    updated_at timestamp with time zone, 
    parent_client_name text, 
    branches jsonb
)
 LANGUAGE plpgsql
AS $function$
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
$function$;

--------------------------------------------------------------------------------
-- 2. assign_prototype_to_client (Deprecated by assign_treatment_to_client but updated for safety)
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.assign_prototype_to_client(uuid, uuid, uuid, text, date, numeric);
CREATE OR REPLACE FUNCTION public.assign_prototype_to_client(
    p_tenant_id uuid, 
    p_platform_id uuid,
    p_client_id uuid, 
    p_prototype_id uuid, 
    p_selected_price_type text, 
    p_start_date date, 
    p_custom_final_price numeric DEFAULT NULL::numeric
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_client_treatment_id UUID;
  v_prototype RECORD;
  v_final_price NUMERIC;
  v_session RECORD;
  v_calculated_payment_amount NUMERIC;
  v_created_client_treatment JSONB;
BEGIN
  SELECT * INTO v_prototype FROM treatments WHERE id = p_prototype_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Prototipo no encontrado.';
  END IF;

  IF p_custom_final_price IS NOT NULL THEN
    v_final_price = p_custom_final_price;
  ELSIF p_selected_price_type = 'upfront' THEN
    v_final_price = v_prototype.upfront_price;
  ELSIF p_selected_price_type = 'financed' THEN
    v_final_price = v_prototype.financed_price;
  ELSE
    RAISE EXCEPTION 'Tipo de precio seleccionado no válido: %', p_selected_price_type;
  END IF;

  INSERT INTO client_treatments (client_id, tenant_id, platform_id, prototype_id, name, final_price, start_date, payment_type)
  VALUES (p_client_id, p_tenant_id, p_platform_id, p_prototype_id, v_prototype.name, v_final_price, p_start_date, p_selected_price_type)
  RETURNING id INTO v_client_treatment_id;

  FOR v_session IN
    SELECT * FROM treatment_sessions WHERE treatment_id = p_prototype_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id ORDER BY session_number
  LOOP
    v_calculated_payment_amount := 0;
    IF p_selected_price_type = 'upfront' AND v_session.session_number = 1 THEN
      v_calculated_payment_amount := v_final_price;
    ELSIF p_selected_price_type = 'financed' THEN
      IF v_session.fixed_payment_amount IS NOT NULL AND v_session.fixed_payment_amount > 0 THEN
        v_calculated_payment_amount := v_session.fixed_payment_amount;
      ELSIF v_session.payment_percentage IS NOT NULL AND v_session.payment_percentage > 0 THEN
        v_calculated_payment_amount := v_final_price * (v_session.payment_percentage / 100.0);
      END IF;
    END IF;

    INSERT INTO client_treatment_sessions (client_treatment_id, tenant_id, platform_id, prototype_session_id, session_number, name, description, payment_amount)
    VALUES (v_client_treatment_id, p_tenant_id, p_platform_id, v_session.id, v_session.session_number, v_session.name, v_session.description, v_calculated_payment_amount);
  END LOOP;

  SELECT get_client_treatment_details(p_tenant_id, p_platform_id, v_client_treatment_id) INTO v_created_client_treatment;
  RETURN v_created_client_treatment;
END;
$function$;

--------------------------------------------------------------------------------
-- 3. get_client_treatments
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_client_treatments(uuid);
CREATE OR REPLACE FUNCTION public.get_client_treatments(p_tenant_id uuid, p_platform_id uuid, p_client_id uuid)
 RETURNS TABLE(id uuid, name text, status text, start_date date, progress jsonb, has_scheduled_sessions boolean)
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN QUERY
    WITH treatment_progress AS (
        SELECT
            cts.client_treatment_id,
            COUNT(*) AS total,
            COUNT(*) FILTER (WHERE cts.status IN ('completed', 'Cita Asignada', 'Cancelada')) AS completed,
            BOOL_OR(cts.status = 'Cita Asignada') as has_scheduled_sessions
        FROM
            public.client_treatment_sessions cts
        WHERE cts.tenant_id = p_tenant_id AND cts.platform_id = p_platform_id
        GROUP BY
            cts.client_treatment_id
    )
    SELECT
        ct.id,
        ct.name,
        ct.status,
        ct.start_date,
        jsonb_build_object(
            'total', COALESCE(tp.total, 0),
            'completed', COALESCE(tp.completed, 0)
        ) AS progress,
        COALESCE(tp.has_scheduled_sessions, false) as has_scheduled_sessions
    FROM
        public.client_treatments ct
    LEFT JOIN
        treatment_progress tp ON ct.id = tp.client_treatment_id
    WHERE
        ct.client_id = p_client_id
        AND ct.tenant_id = p_tenant_id
        AND ct.platform_id = p_platform_id
    ORDER BY
        ct.created_at DESC;
END;
$function$;

--------------------------------------------------------------------------------
-- 4. get_client_treatment_details
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_client_treatment_details(uuid);
CREATE OR REPLACE FUNCTION public.get_client_treatment_details(p_tenant_id uuid, p_platform_id uuid, p_client_treatment_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_details jsonb;
BEGIN
    SELECT jsonb_build_object(
        'id', ct.id,
        'client_id', ct.client_id,
        'prototype_id', ct.prototype_id,
        'name', ct.name,
        'description', t.description,
        'status', ct.status,
        'start_date', ct.start_date,
        'final_price', ct.final_price,
        'payment_type', ct.payment_type,
        'cover_image_url', (SELECT ti.image_url FROM public.treatment_images ti WHERE ti.treatment_id = t.id AND ti.is_primary = TRUE AND ti.tenant_id = p_tenant_id AND ti.platform_id = p_platform_id LIMIT 1),
        'sessions', COALESCE(
            (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'id', cts.id,
                        'session_number', cts.session_number,
                        'name', cts.name,
                        'description', cts.description,
                        'status', cts.status,
                        'completed_at', cts.completed_at,
                        'attention_id', cts.attention_id,
                        'attention_datetime', a.attention_datetime,
                        'payment_due', jsonb_build_object(
                            'amount', cts.payment_due_amount,
                            'status', cts.payment_status
                        ),
                        'items', COALESCE(
                            (
                                SELECT jsonb_agg(
                                    jsonb_build_object(
                                        'id', ctsi.id,
                                        'product_id', ctsi.product_id,
                                        'service_id', ctsi.service_id,
                                        'quantity', ctsi.quantity,
                                        'notes', ctsi.notes,
                                        'product_name', p.name,
                                        'service_name', s.name
                                    )
                                )
                                FROM public.client_treatment_session_items ctsi
                                LEFT JOIN public.products p ON ctsi.product_id = p.id AND ctsi.tenant_id = p.tenant_id AND ctsi.platform_id = p.platform_id
                                LEFT JOIN public.services s ON ctsi.service_id = s.id AND ctsi.tenant_id = s.tenant_id AND ctsi.platform_id = s.platform_id
                                WHERE ctsi.client_treatment_session_id = cts.id
                                  AND ctsi.tenant_id = p_tenant_id AND ctsi.platform_id = p_platform_id
                            ),
                            '[]'::jsonb
                        )
                    )
                    ORDER BY cts.session_number
                )
                FROM public.client_treatment_sessions cts
                LEFT JOIN public.attentions a ON cts.attention_id = a.id AND cts.tenant_id = a.tenant_id AND cts.platform_id = a.platform_id
                WHERE cts.client_treatment_id = ct.id
                  AND cts.tenant_id = p_tenant_id AND cts.platform_id = p_platform_id
            ),
            '[]'::jsonb
        )
    )
    INTO v_details
    FROM
        public.client_treatments ct
    LEFT JOIN
        public.treatments t ON ct.prototype_id = t.id AND ct.tenant_id = t.tenant_id AND ct.platform_id = t.platform_id
    WHERE
        ct.id = p_client_treatment_id
        AND ct.tenant_id = p_tenant_id
        AND ct.platform_id = p_platform_id;

    RETURN v_details;
END;
$function$;

--------------------------------------------------------------------------------
-- 5. delete_client_treatment
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.delete_client_treatment(uuid, uuid);
CREATE OR REPLACE FUNCTION public.delete_client_treatment(p_tenant_id uuid, p_platform_id uuid, p_client_treatment_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_session_started_count integer;
    v_deleted_id uuid;
BEGIN
    -- Security check: Ensure the treatment belongs to the correct tenant/platform
    IF NOT EXISTS (
        SELECT 1 FROM public.client_treatments 
        WHERE id = p_client_treatment_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id
    ) THEN
        RAISE EXCEPTION 'Treatment not found or permission denied';
    END IF;

    -- Check if any session has a status other than 'pending'
    SELECT count(*)
    INTO v_session_started_count
    FROM public.client_treatment_sessions
    WHERE client_treatment_id = p_client_treatment_id
      AND tenant_id = p_tenant_id AND platform_id = p_platform_id
      AND status <> 'pending';

    IF v_session_started_count > 0 THEN
        RAISE EXCEPTION 'No se puede eliminar un tratamiento que ya ha iniciado.';
    END IF;

    -- If checks pass, delete the treatment. Cascade should handle the rest.
    DELETE FROM public.client_treatments
    WHERE id = p_client_treatment_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id
    RETURNING id INTO v_deleted_id;

    RETURN v_deleted_id;
END;
$function$;

--------------------------------------------------------------------------------
-- 6. assign_treatment_to_client
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.assign_treatment_to_client(uuid, uuid, uuid, text, text, numeric, date, jsonb);
CREATE OR REPLACE FUNCTION public.assign_treatment_to_client(
    p_tenant_id uuid, 
    p_platform_id uuid,
    p_client_id uuid, 
    p_prototype_id uuid, 
    p_custom_name text, 
    p_payment_type text, 
    p_custom_final_price numeric, 
    p_start_date date, 
    p_sessions jsonb
)
 RETURNS client_treatments
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_treatment public.treatments;
    v_new_client_treatment public.client_treatments;
    session_data jsonb;
    v_client_treatment_session_id uuid;
    item_data jsonb;
BEGIN
    -- 1. Get treatment (prototype) details
    SELECT * INTO v_treatment FROM public.treatments WHERE id = p_prototype_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Treatment prototype not found.';
    END IF;

    -- 2. Create the main client_treatments record
    INSERT INTO public.client_treatments (
        tenant_id,
        platform_id,
        client_id,
        prototype_id,
        name,
        status,
        start_date,
        final_price,
        payment_type
    )
    VALUES (
        p_tenant_id,
        p_platform_id,
        p_client_id,
        p_prototype_id,
        p_custom_name,
        'active',
        p_start_date,
        p_custom_final_price,
        p_payment_type
    )
    RETURNING * INTO v_new_client_treatment;

    -- 3. Create client_treatment_sessions from the provided JSON array
    IF NOT jsonb_typeof(p_sessions) = 'array' THEN
        RAISE EXCEPTION 'p_sessions must be an array of session objects.';
    END IF;

    FOR session_data IN SELECT * FROM jsonb_array_elements(p_sessions)
    LOOP
        INSERT INTO public.client_treatment_sessions (
            client_treatment_id,
            tenant_id,
            platform_id,
            prototype_session_id,
            session_number,
            name,
            description,
            payment_due_amount
        )
        VALUES (
            v_new_client_treatment.id,
            p_tenant_id,
            p_platform_id,
            (session_data->>'id')::uuid,
            (session_data->>'session_number')::integer,
            session_data->>'name',
            session_data->>'description',
            (session_data->>'payment_amount')::numeric
        )
        RETURNING id INTO v_client_treatment_session_id;

        -- Insert associated items for this session
        IF session_data->'items' IS NOT NULL AND jsonb_typeof(session_data->'items') = 'array' THEN
            FOR item_data IN SELECT * FROM jsonb_array_elements(session_data->'items')
            LOOP
                INSERT INTO public.client_treatment_session_items (
                    client_treatment_session_id,
                    tenant_id,
                    platform_id,
                    product_id,
                    service_id,
                    quantity,
                    notes
                )
                VALUES (
                    v_client_treatment_session_id,
                    p_tenant_id,
                    p_platform_id,
                    (item_data->>'product_id')::uuid,
                    (item_data->>'service_id')::uuid,
                    (item_data->>'quantity')::integer,
                    item_data->>'notes'
                );
            END LOOP;
        END IF;
    END LOOP;

    RETURN v_new_client_treatment;
END;
$function$;

--------------------------------------------------------------------------------
-- 7. complete_client_treatment_session
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.complete_client_treatment_session(uuid, uuid, uuid);
CREATE OR REPLACE FUNCTION public.complete_client_treatment_session(p_tenant_id uuid, p_platform_id uuid, p_session_id uuid, p_attention_id uuid)
 RETURNS client_treatment_sessions
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_session public.client_treatment_sessions;
BEGIN
    UPDATE public.client_treatment_sessions
    SET
        status = 'completed',
        completed_at = now(),
        attention_id = p_attention_id
    WHERE
        id = p_session_id
        AND tenant_id = p_tenant_id AND platform_id = p_platform_id
    RETURNING * INTO v_session;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Client treatment session not found.';
    END IF;

    -- Optionally, update the parent client_treatment status if all sessions are completed
    PERFORM public.update_client_treatment_status_if_completed(v_session.client_treatment_id);

    RETURN v_session;
END;
$function$;

--------------------------------------------------------------------------------
-- 8. link_signature_to_consent
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.link_signature_to_consent(uuid, uuid, text, jsonb, text);
CREATE OR REPLACE FUNCTION public.link_signature_to_consent(
    p_tenant_id uuid, 
    p_platform_id uuid,
    p_signed_consent_id uuid, 
    p_observations text, 
    p_form_data jsonb, 
    p_signed_content text
)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
BEGIN
    UPDATE public.signed_consents
    SET
        professional_observations = p_observations,
        signed_at = NOW(),
        form_data = p_form_data,
        signed_content = p_signed_content
    WHERE
        id = p_signed_consent_id
        AND tenant_id = p_tenant_id
        AND platform_id = p_platform_id;
END;
$function$;

--------------------------------------------------------------------------------
-- 9. sign_consent
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.sign_consent(uuid, uuid, text, text);
CREATE OR REPLACE FUNCTION public.sign_consent(
    p_tenant_id uuid, 
    p_platform_id uuid,
    p_signed_consent_id uuid, 
    p_signature text, 
    p_observations text
)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
BEGIN
    UPDATE public.signed_consents
    SET
        signed_content = p_signature,
        professional_observations = p_observations,
        signed_at = NOW()
    WHERE
        id = p_signed_consent_id
        AND tenant_id = p_tenant_id
        AND platform_id = p_platform_id;
END;
$function$;

--------------------------------------------------------------------------------
-- 10. delete_signed_consent
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.delete_signed_consent(uuid, uuid);
CREATE OR REPLACE FUNCTION public.delete_signed_consent(p_tenant_id uuid, p_platform_id uuid, p_signed_consent_id uuid)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
BEGIN
    DELETE FROM public.signed_consents
    WHERE
        id = p_signed_consent_id
        AND tenant_id = p_tenant_id
        AND platform_id = p_platform_id
        AND signed_at IS NULL;
END;
$function$;

--------------------------------------------------------------------------------
-- 11. get_signed_consents_for_attention
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_signed_consents_for_attention(uuid, uuid, uuid);
CREATE OR REPLACE FUNCTION public.get_signed_consents_for_attention(
    p_tenant_id uuid, 
    p_platform_id uuid,
    p_attention_id uuid, 
    p_attention_service_id uuid DEFAULT NULL::uuid
)
 RETURNS TABLE(
    id uuid, 
    attention_id uuid, 
    client_id uuid, 
    professional_id uuid, 
    template_id uuid, 
    template_name text, 
    template_content text, 
    professional_observations text, 
    signed_content text, 
    signed_at timestamp with time zone, 
    created_at timestamp with time zone, 
    updated_at timestamp with time zone, 
    attention_service_id uuid, 
    signature_file_id text
)
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN QUERY
    SELECT DISTINCT ON (sc.id) -- Ensure one row per signed_consent
        sc.id,
        sc.attention_id,
        sc.client_id,
        sc.professional_id,
        sc.template_id,
        ct.name AS template_name,
        ct.content AS template_content,
        sc.professional_observations,
        sc.signed_content,
        sc.signed_at,
        sc.created_at,
        sc.updated_at,
        sc.attention_service_id,
        cs.google_drive_file_id AS signature_file_id
    FROM
        public.signed_consents sc
    JOIN
        public.informed_consent_templates ct ON sc.template_id = ct.id AND sc.tenant_id = ct.tenant_id AND sc.platform_id = ct.platform_id
    LEFT JOIN
        public.consent_signatures cs ON sc.id = cs.signed_consent_id AND sc.tenant_id = cs.tenant_id AND sc.platform_id = cs.platform_id
    WHERE
        sc.tenant_id = p_tenant_id
        AND sc.platform_id = p_platform_id
        AND sc.attention_id = p_attention_id
        AND (p_attention_service_id IS NULL OR sc.attention_service_id = p_attention_service_id)
    ORDER BY sc.id, cs.created_at DESC; -- Get the most recent signature for each consent
END;
$function$;

--------------------------------------------------------------------------------
-- 12. assign_consent_to_service
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.assign_consent_to_service(uuid, uuid, uuid, uuid, text);
CREATE OR REPLACE FUNCTION public.assign_consent_to_service(
    p_tenant_id uuid, 
    p_platform_id uuid,
    p_attention_id uuid, 
    p_template_id uuid, 
    p_attention_service_id uuid, 
    p_professional_observations text DEFAULT NULL::text
)
 RETURNS signed_consents
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_client_id uuid;
    v_professional_id uuid;
    new_signed_consent public.signed_consents;
BEGIN
    -- Fetch client_id from the attentions table
    SELECT
        a.client_id
    INTO
        v_client_id
    FROM
        public.attentions a
    WHERE
        a.id = p_attention_id AND a.tenant_id = p_tenant_id AND a.platform_id = p_platform_id;

    -- Check if attention exists and tenant matches
    IF v_client_id IS NULL THEN
        RAISE EXCEPTION 'Attention with ID % not found for tenant % and platform %', p_attention_id, p_tenant_id, p_platform_id;
    END IF;

    -- Fetch professional_id from the attention_services table
    SELECT
        ats.user_id
    INTO
        v_professional_id
    FROM
        public.attention_services ats
    WHERE
        ats.id = p_attention_service_id AND ats.attention_id = p_attention_id AND ats.tenant_id = p_tenant_id AND ats.platform_id = p_platform_id;

    -- Check if attention service exists and tenant/attention matches
    IF v_professional_id IS NULL THEN
        RAISE EXCEPTION 'Attention Service with ID % not found for attention % and tenant % and platform %', p_attention_service_id, p_attention_id, p_tenant_id, p_platform_id;
    END IF;

    -- Insert a new signed_consents record (initially unsigned)
    INSERT INTO public.signed_consents (
        attention_id,
        client_id,
        professional_id,
        template_id,
        tenant_id,
        platform_id,
        attention_service_id,
        professional_observations,
        signed_content,
        signed_at
    )
    VALUES (
        p_attention_id,
        v_client_id,
        v_professional_id,
        p_template_id,
        p_tenant_id,
        p_platform_id,
        p_attention_service_id,
        p_professional_observations,
        NULL,
        NULL
    )
    RETURNING * INTO new_signed_consent;

    RETURN new_signed_consent;
END;
$function$;

COMMIT;
