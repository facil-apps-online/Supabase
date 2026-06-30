-- Migration to create the RPC function for bulk-inserting client treatment sessions.

DROP FUNCTION IF EXISTS public.create_client_treatment_sessions(uuid, jsonb);

CREATE OR REPLACE FUNCTION public.create_client_treatment_sessions(
    p_client_treatment_id uuid,
    p_sessions jsonb
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    session_data jsonb;
BEGIN
    -- Check if p_sessions is a valid JSON array
    IF NOT jsonb_typeof(p_sessions) = 'array' THEN
        RAISE EXCEPTION 'Payload must be an array of session objects.';
    END IF;

    -- Loop through each object in the JSON array and insert it into the table
    FOR session_data IN SELECT * FROM jsonb_array_elements(p_sessions)
    LOOP
        INSERT INTO public.client_treatment_sessions (
            client_treatment_id,
            session_number,
            name,
            payment_due_amount,
            payment_due_percentage,
            status 
        )
        VALUES (
            p_client_treatment_id,
            (session_data->>'session_number')::integer,
            session_data->>'name',
            (session_data->>'payment_amount')::numeric,
            (session_data->>'payment_percentage')::numeric,
            'pending' -- Default status
        );
    END LOOP;
END;
$$;
