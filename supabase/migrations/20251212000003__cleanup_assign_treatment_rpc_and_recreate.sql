-- Drop the function with the old, incorrect signature if it exists
DROP FUNCTION IF EXISTS public.assign_treatment_to_client(uuid, uuid, uuid, text, text, numeric, timestamp with time zone, jsonb);

-- Drop the function with the new, correct signature if it exists, to ensure a clean re-creation
DROP FUNCTION IF EXISTS public.assign_treatment_to_client(uuid, uuid, uuid, text, text, numeric, date, jsonb);

-- Recreate the function with the correct signature and body
CREATE OR REPLACE FUNCTION public.assign_treatment_to_client(
    p_tenant_id uuid,
    p_client_id uuid,
    p_prototype_id uuid,
    p_custom_name text,
    p_payment_type text,
    p_custom_final_price numeric,
    p_start_date date,
    p_sessions jsonb
)
RETURNS public.client_treatments
LANGUAGE 'plpgsql'
AS $BODY$
DECLARE
    v_treatment public.treatments;
    v_new_client_treatment public.client_treatments;
    session_data jsonb;
    v_client_treatment_session_id uuid;
    item_data jsonb;
BEGIN
    -- 1. Get treatment (prototype) details
    SELECT * INTO v_treatment FROM public.treatments WHERE id = p_prototype_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Treatment prototype not found.';
    END IF;

    -- 2. Create the main client_treatments record
    INSERT INTO public.client_treatments (
        tenant_id,
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
            prototype_session_id,
            session_number,
            name,
            description,
            payment_due_amount
        )
        VALUES (
            v_new_client_treatment.id,
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
                    product_id,
                    service_id,
                    quantity,
                    notes
                )
                VALUES (
                    v_client_treatment_session_id,
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
$BODY$;