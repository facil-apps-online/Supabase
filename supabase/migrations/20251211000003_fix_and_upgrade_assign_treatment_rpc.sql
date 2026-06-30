-- This migration fixes and upgrades the assign_treatment_to_client RPC function.
-- 1. Drops the old, incorrect version of the function.
-- 2. Drops the now-redundant create_client_treatment_sessions function.
-- 3. Creates a new, single RPC function that handles the assignment and the custom session creation in one atomic step.

DROP FUNCTION IF EXISTS public.assign_treatment_to_client(uuid, uuid, uuid, text, numeric, timestamptz);
DROP FUNCTION IF EXISTS public.create_client_treatment_sessions(uuid, jsonb);

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
BEGIN
    -- 1. Get treatment (prototype) details
    SELECT * INTO v_treatment FROM public.treatments WHERE id = p_treatment_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Treatment prototype not found.';
    END IF;

    -- 2. Create the main client_treatments record
    --    CORRECTED: Using 'prototype_id' instead of 'treatment_id'
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
        );
    END LOOP;

    RETURN v_new_client_treatment;
END;
$$;
