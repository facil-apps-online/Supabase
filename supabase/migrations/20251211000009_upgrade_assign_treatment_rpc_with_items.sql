-- This migration upgrades the assign_treatment_to_client RPC function
-- to handle the insertion of nested session items into the new
-- 'client_treatment_session_items' table.

DROP FUNCTION IF EXISTS public.assign_treatment_to_client(uuid, uuid, uuid, text, numeric, timestamptz, jsonb);

CREATE OR REPLACE FUNCTION public.assign_treatment_to_client(
    p_tenant_id uuid,
    p_client_id uuid,
    p_treatment_id uuid, -- This is the prototype_id
    p_selected_price_type text,
    p_custom_final_price numeric,
    p_start_date timestamptz,
    p_sessions jsonb -- The array of custom sessions from the frontend
)
 RETURNS public.client_treatments
 LANGUAGE plpgsql
AS $$
DECLARE
    v_treatment public.treatments;
    v_new_client_treatment public.client_treatments;
    session_data jsonb;
    v_client_treatment_session_id uuid; -- To store the ID of the newly created client session
    item_data jsonb; -- To iterate over session items
BEGIN
    -- 1. Get treatment (prototype) details
    SELECT * INTO v_treatment FROM public.treatments WHERE id = p_treatment_id;
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
        v_treatment.id,
        v_treatment.name,
        'active',
        p_start_date,
        p_custom_final_price,
        p_selected_price_type
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
            session_number,
            name,
            payment_due_amount
        )
        VALUES (
            v_new_client_treatment.id,
            (session_data->>'session_number')::integer,
            session_data->>'name',
            (session_data->>'payment_amount')::numeric
        )
        RETURNING id INTO v_client_treatment_session_id; -- Get the ID of the newly created session

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
$$;
