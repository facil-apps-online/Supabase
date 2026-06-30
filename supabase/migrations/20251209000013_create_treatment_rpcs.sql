DROP FUNCTION IF EXISTS public.list_treatment_prototypes(uuid, text);
DROP FUNCTION IF EXISTS public.get_treatment_prototype_details(uuid);
DROP FUNCTION IF EXISTS public.create_treatment_prototype(uuid, text, text, text, numeric, numeric, jsonb);
DROP FUNCTION IF EXISTS public.update_treatment_prototype(uuid, uuid, text, text, numeric, numeric, jsonb);
DROP FUNCTION IF EXISTS public.delete_treatment_prototype(uuid, uuid);
DROP FUNCTION IF EXISTS public.assign_prototype_to_client(uuid, uuid, uuid, text, numeric, timestamptz);
DROP FUNCTION IF EXISTS public.get_client_treatments(uuid);
DROP FUNCTION IF EXISTS public.get_client_treatment_details(uuid);

-- RPC: list_treatments
CREATE OR REPLACE FUNCTION public.list_treatments(p_tenant_id uuid, p_type text)
 RETURNS TABLE(id uuid, name text, description text, type text, upfront_price numeric, financed_price numeric, session_count bigint, cover_image_url text)
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN QUERY
    SELECT
        t.id,
        t.name,
        t.description,
        t.type,
        t.upfront_price,
        t.financed_price,
        COUNT(ts.id) AS session_count,
        (SELECT ti.image_url FROM public.treatment_images ti WHERE ti.treatment_id = t.id AND ti.is_primary = TRUE LIMIT 1) AS cover_image_url
    FROM
        public.treatments t
    LEFT JOIN
        public.treatment_sessions ts ON t.id = ts.treatment_id
    WHERE
        t.tenant_id = p_tenant_id AND t.type = p_type
    GROUP BY
        t.id
    ORDER BY
        t.name;
END;
$function$;

-- RPC: create_treatment
CREATE OR REPLACE FUNCTION public.create_treatment(
    p_tenant_id uuid,
    p_name text,
    p_description text,
    p_type text,
    p_upfront_price numeric,
    p_financed_price numeric,
    p_sessions jsonb -- Array of session objects
)
 RETURNS public.treatments
 LANGUAGE plpgsql
AS $function$
DECLARE
    new_treatment public.treatments;
    session_data jsonb;
    new_session_id uuid;
    item_data jsonb;
BEGIN
    INSERT INTO public.treatments (tenant_id, name, description, type, upfront_price, financed_price)
    VALUES (p_tenant_id, p_name, p_description, p_type, p_upfront_price, p_financed_price)
    RETURNING * INTO new_treatment;

    IF p_sessions IS NOT NULL AND jsonb_array_length(p_sessions) > 0 THEN
        FOR session_data IN SELECT * FROM jsonb_array_elements(p_sessions) LOOP
            INSERT INTO public.treatment_sessions (
                treatment_id,
                session_number,
                name,
                description,
                payment_percentage,
                fixed_payment_amount
            )
            VALUES (
                new_treatment.id,
                (session_data->>'session_number')::int,
                session_data->>'name',
                session_data->>'description',
                (NULLIF(session_data->>'payment_percentage', 'null'))::numeric,
                (NULLIF(session_data->>'fixed_payment_amount', 'null'))::numeric
            )
            RETURNING id INTO new_session_id;

            IF session_data->'items' IS NOT NULL AND jsonb_array_length(session_data->'items') > 0 THEN
                FOR item_data IN SELECT * FROM jsonb_array_elements(session_data->'items') LOOP
                    INSERT INTO public.treatment_session_items (
                        session_id,
                        product_id,
                        service_id,
                        quantity,
                        notes
                    )
                    VALUES (
                        new_session_id,
                        (item_data->>'product_id')::uuid,
                        (item_data->>'service_id')::uuid,
                        (item_data->>'quantity')::int,
                        item_data->>'notes'
                    );
                END LOOP;
            END IF;
        END LOOP;
    END IF;

    RETURN new_treatment;
END;
$function$;


-- RPC: update_treatment
CREATE OR REPLACE FUNCTION public.update_treatment(
    p_treatment_id uuid,
    p_tenant_id uuid,
    p_name text,
    p_description text,
    p_upfront_price numeric,
    p_financed_price numeric,
    p_sessions jsonb -- Array of session objects
)
 RETURNS public.treatments
 LANGUAGE plpgsql
AS $function$
DECLARE
    updated_treatment public.treatments;
    session_data jsonb;
    new_session_id uuid;
    item_data jsonb;
BEGIN
    UPDATE public.treatments
    SET
        name = p_name,
        description = p_description,
        upfront_price = p_upfront_price,
        financed_price = p_financed_price,
        updated_at = now()
    WHERE
        id = p_treatment_id AND tenant_id = p_tenant_id
    RETURNING * INTO updated_treatment;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Treatment not found or not owned by tenant.';
    END IF;

    -- Delete existing sessions and items to re-insert (simpler than complex diffing)
    DELETE FROM public.treatment_session_items
    WHERE session_id IN (SELECT id FROM public.treatment_sessions WHERE treatment_id = p_treatment_id);

    DELETE FROM public.treatment_sessions
    WHERE treatment_id = p_treatment_id;

    -- Insert new sessions and items
    IF p_sessions IS NOT NULL AND jsonb_array_length(p_sessions) > 0 THEN
        FOR session_data IN SELECT * FROM jsonb_array_elements(p_sessions) LOOP
            INSERT INTO public.treatment_sessions (
                treatment_id,
                session_number,
                name,
                description,
                payment_percentage,
                fixed_payment_amount
            )
            VALUES (
                updated_treatment.id,
                (session_data->>'session_number')::int,
                session_data->>'name',
                session_data->>'description',
                (NULLIF(session_data->>'payment_percentage', 'null'))::numeric,
                (NULLIF(session_data->>'fixed_payment_amount', 'null'))::numeric
            )
            RETURNING id INTO new_session_id;

            IF session_data->'items' IS NOT NULL AND jsonb_array_length(session_data->'items') > 0 THEN
                FOR item_data IN SELECT * FROM jsonb_array_elements(session_data->'items') LOOP
                    INSERT INTO public.treatment_session_items (
                        session_id,
                        product_id,
                        service_id,
                        quantity,
                        notes
                    )
                    VALUES (
                        new_session_id,
                        (item_data->>'product_id')::uuid,
                        (item_data->>'service_id')::uuid,
                        (item_data->>'quantity')::int,
                        item_data->>'notes'
                    );
                END LOOP;
            END IF;
        END LOOP;
    END IF;

    RETURN updated_treatment;
END;
$function$;

-- RPC: delete_treatment
CREATE OR REPLACE FUNCTION public.delete_treatment(
    p_treatment_id uuid,
    p_tenant_id uuid
)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
BEGIN
    DELETE FROM public.treatments
    WHERE id = p_treatment_id AND tenant_id = p_tenant_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Treatment not found or not owned by tenant.';
    END IF;
END;
$function$;

-- RPC: get_treatment_images
CREATE OR REPLACE FUNCTION public.get_treatment_images(p_treatment_id uuid)
 RETURNS TABLE(id uuid, treatment_id uuid, tenant_id uuid, image_url text, is_primary boolean, sort_order integer, created_at timestamptz, updated_at timestamptz, google_drive_file_id text, file_name text, mime_type text, file_size bigint)
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN QUERY
    SELECT
        ti.id,
        ti.treatment_id,
        ti.tenant_id,
        ti.image_url,
        ti.is_primary,
        ti.sort_order,
        ti.created_at,
        ti.updated_at,
        ti.google_drive_file_id,
        ti.file_name,
        ti.mime_type,
        ti.file_size
    FROM
        public.treatment_images ti
    WHERE
        ti.treatment_id = p_treatment_id
    ORDER BY
        ti.sort_order ASC, ti.created_at ASC;
END;
$function$;

-- RPC: delete_treatment_image
CREATE OR REPLACE FUNCTION public.delete_treatment_image(p_image_id uuid)
 RETURNS uuid -- Returns the google_drive_file_id of the deleted image
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_google_drive_file_id text;
BEGIN
    SELECT google_drive_file_id INTO v_google_drive_file_id
    FROM public.treatment_images
    WHERE id = p_image_id;

    IF v_google_drive_file_id IS NULL THEN
        RAISE EXCEPTION 'Treatment image not found.';
    END IF;

    DELETE FROM public.treatment_images
    WHERE id = p_image_id;

    RETURN v_google_drive_file_id;
END;
$function$;

-- RPC: set_primary_image_for_treatment
CREATE OR REPLACE FUNCTION public.set_primary_image_for_treatment(
    p_tenant_id uuid,
    p_treatment_id uuid,
    p_image_id uuid
)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- Set all images for this treatment to not primary
    UPDATE public.treatment_images
    SET is_primary = FALSE
    WHERE treatment_id = p_treatment_id AND tenant_id = p_tenant_id;

    -- Set the specified image as primary
    UPDATE public.treatment_images
    SET is_primary = TRUE
    WHERE id = p_image_id AND treatment_id = p_treatment_id AND tenant_id = p_tenant_id;

    -- Update the treatment's cover_image_url
    UPDATE public.treatments
    SET cover_image_url = (SELECT image_url FROM public.treatment_images WHERE id = p_image_id)
    WHERE id = p_treatment_id;
END;
$function$;

-- RPC: update_treatment_images_order
CREATE OR REPLACE FUNCTION public.update_treatment_images_order(
    p_tenant_id uuid,
    p_treatment_id uuid,
    p_images_data jsonb[] -- Array of {id: uuid, sort_order: int}
)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
    image_data jsonb;
BEGIN
    FOR image_data IN SELECT * FROM unnest(p_images_data) LOOP
        UPDATE public.treatment_images
        SET
            sort_order = (image_data->>'sort_order')::int
        WHERE
            id = (image_data->>'id')::uuid
            AND treatment_id = p_treatment_id
            AND tenant_id = p_tenant_id;
    END LOOP;
END;
$function$;

-- RPC: assign_treatment_to_client
CREATE OR REPLACE FUNCTION public.assign_treatment_to_client(
    p_tenant_id uuid,
    p_client_id uuid,
    p_treatment_id uuid,
    p_selected_price_type text, -- 'upfront' or 'financed'
    p_custom_final_price numeric, -- Optional custom price
    p_start_date timestamptz
)
 RETURNS public.client_treatments
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_treatment public.treatments;
    v_new_client_treatment public.client_treatments;
    session_record record;
    v_final_price numeric(10, 2);
BEGIN
    -- 1. Get treatment details
    SELECT * INTO v_treatment FROM public.treatments WHERE id = p_treatment_id AND tenant_id = p_tenant_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Treatment not found.';
    END IF;

    -- 2. Determine final price
    IF p_custom_final_price IS NOT NULL THEN
        v_final_price := p_custom_final_price;
    ELSIF p_selected_price_type = 'upfront' THEN
        v_final_price := v_treatment.upfront_price;
    ELSIF p_selected_price_type = 'financed' THEN
        v_final_price := v_treatment.financed_price;
    ELSE
        RAISE EXCEPTION 'Invalid selected_price_type. Must be "upfront" or "financed".';
    END IF;

    -- 3. Create client_treatments entry
    INSERT INTO public.client_treatments (
        tenant_id,
        client_id,
        treatment_id,
        name,
        description,
        status,
        start_date,
        final_price,
        payment_type
    )
    VALUES (
        p_tenant_id,
        p_client_id,
        v_treatment.id,
        v_treatment.name,
        v_treatment.description,
        'active', -- Default status
        p_start_date,
        v_final_price,
        p_selected_price_type
    )
    RETURNING * INTO v_new_client_treatment;

    -- 4. Create client_treatment_sessions based on treatment_sessions
    FOR session_record IN SELECT * FROM public.treatment_sessions WHERE treatment_id = v_treatment.id ORDER BY session_number LOOP
        INSERT INTO public.client_treatment_sessions (
            client_treatment_id,
            session_number,
            name,
            description,
            status,
            payment_due_amount, -- Adjusted for potential payment scheduling
            payment_due_percentage
        )
        VALUES (
            v_new_client_treatment.id,
            session_record.session_number,
            session_record.name,
            session_record.description,
            'pending',
            CASE WHEN session_record.fixed_payment_amount IS NOT NULL THEN session_record.fixed_payment_amount ELSE NULL END,
            CASE WHEN session_record.payment_percentage IS NOT NULL THEN session_record.payment_percentage ELSE NULL END
        );
    END LOOP;

    RETURN v_new_client_treatment;
END;
$function$;

-- RPC: get_client_treatments
CREATE OR REPLACE FUNCTION public.get_client_treatments(p_client_id uuid)
 RETURNS TABLE(id uuid, name text, status text, start_date timestamptz, completed_sessions bigint, total_sessions bigint, cover_image_url text)
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN QUERY
    SELECT
        ct.id,
        ct.name,
        ct.status,
        ct.start_date,
        (SELECT COUNT(cts.id) FROM public.client_treatment_sessions cts WHERE cts.client_treatment_id = ct.id AND cts.status = 'completed') AS completed_sessions,
        (SELECT COUNT(cts.id) FROM public.client_treatment_sessions cts WHERE cts.client_treatment_id = ct.id) AS total_sessions,
        (SELECT ti.image_url FROM public.treatment_images ti WHERE ti.treatment_id = t.id AND ti.is_primary = TRUE LIMIT 1) AS cover_image_url
    FROM
        public.client_treatments ct
    JOIN
        public.treatments t ON ct.treatment_id = t.id
    WHERE
        ct.client_id = p_client_id
    ORDER BY
        ct.start_date DESC;
END;
$function$;

-- RPC: get_client_treatment_details
CREATE OR REPLACE FUNCTION public.get_client_treatment_details(p_client_treatment_id uuid)
 RETURNS TABLE(id uuid, client_id uuid, treatment_id uuid, name text, description text, status text, start_date timestamptz, final_price numeric, payment_type text, cover_image_url text, sessions jsonb)
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN QUERY
    SELECT
        ct.id,
        ct.client_id,
        ct.treatment_id,
        ct.name,
        ct.description,
        ct.status,
        ct.start_date,
        ct.final_price,
        ct.payment_type,
        (SELECT ti.image_url FROM public.treatment_images ti WHERE ti.treatment_id = t.id AND ti.is_primary = TRUE LIMIT 1) AS cover_image_url,
        COALESCE(
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
                        'payment_due', jsonb_build_object(
                            'amount', cts.payment_due_amount,
                            'percentage', cts.payment_due_percentage,
                            'status', cts.payment_status
                        )
                    )
                    ORDER BY cts.session_number
                )
                FROM public.client_treatment_sessions cts
                WHERE cts.client_treatment_id = ct.id
            ),
            '[]'::jsonb
        ) AS sessions
    FROM
        public.client_treatments ct
    JOIN
        public.treatments t ON ct.treatment_id = t.id
    WHERE
        ct.id = p_client_treatment_id;
END;
$function$;

DROP FUNCTION IF EXISTS public.complete_client_treatment_session(uuid, uuid, uuid);
-- RPC: complete_client_treatment_session
CREATE OR REPLACE FUNCTION public.complete_client_treatment_session(
    p_session_id uuid,
    p_attention_id uuid,
    p_tenant_id uuid
)
 RETURNS public.client_treatment_sessions
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
    RETURNING * INTO v_session;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Client treatment session not found.';
    END IF;

    -- Optionally, update the parent client_treatment status if all sessions are completed
    PERFORM public.update_client_treatment_status_if_completed(v_session.client_treatment_id);

    RETURN v_session;
END;
$function$;

-- Helper function to update client_treatment status
CREATE OR REPLACE FUNCTION public.update_client_treatment_status_if_completed(p_client_treatment_id uuid)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
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
$function$;

-- Add new columns to client_treatment_sessions
ALTER TABLE public.client_treatment_sessions
ADD COLUMN payment_due_amount numeric(10, 2) NULL,
ADD COLUMN payment_due_percentage numeric(5, 2) NULL, -- Added this column based on assign_treatment_to_client RPC
ADD COLUMN payment_status text DEFAULT 'pending' NOT NULL;

-- Set existing payment_status to 'pending'
UPDATE public.client_treatment_sessions
SET payment_status = 'pending' WHERE payment_status IS NULL;