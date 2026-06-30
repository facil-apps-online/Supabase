-- Drop the existing function to ensure a clean replacement
DROP FUNCTION IF EXISTS public.update_treatment(p_treatment_id uuid, p_tenant_id uuid, p_name text, p_description text, p_upfront_price numeric, p_financed_price numeric, p_sessions jsonb);

-- Recreate the function with safer, more robust logic
CREATE OR REPLACE FUNCTION public.update_treatment(
    p_treatment_id uuid,
    p_tenant_id uuid,
    p_name text,
    p_description text,
    p_upfront_price numeric,
    p_financed_price numeric,
    p_sessions jsonb
)
RETURNS public.treatments
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    updated_treatment public.treatments;
    session_data jsonb;
    incoming_session_id uuid;
    new_session_id uuid;
    item_data jsonb;
    p_session_ids_to_keep uuid[];
    session_id_to_delete uuid;
BEGIN
    -- First, update the main treatment record
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

    p_session_ids_to_keep := ARRAY[]::uuid[];

    -- Upsert sessions and their items from the payload
    IF p_sessions IS NOT NULL AND jsonb_array_length(p_sessions) > 0 THEN
        FOR session_data IN SELECT * FROM jsonb_array_elements(p_sessions) LOOP
            incoming_session_id := (session_data->>'id')::uuid;

            -- Use INSERT ... ON CONFLICT (UPSERT) for the session
            INSERT INTO public.treatment_sessions (
                id,
                treatment_id,
                session_number,
                name,
                description,
                payment_percentage,
                fixed_payment_amount
            )
            VALUES (
                COALESCE(incoming_session_id, gen_random_uuid()),
                updated_treatment.id,
                (session_data->>'session_number')::int,
                session_data->>'name',
                session_data->>'description',
                (NULLIF(session_data->>'payment_percentage', 'null'))::numeric,
                (NULLIF(session_data->>'fixed_payment_amount', 'null'))::numeric
            )
            ON CONFLICT (id) DO UPDATE SET
                session_number = EXCLUDED.session_number,
                name = EXCLUDED.name,
                description = EXCLUDED.description,
                payment_percentage = EXCLUDED.payment_percentage,
                fixed_payment_amount = EXCLUDED.fixed_payment_amount
            RETURNING id INTO new_session_id;
            
            -- Add the ID of the just-processed session to our list of keepers
            p_session_ids_to_keep := array_append(p_session_ids_to_keep, new_session_id);

            -- Cleanly replace items for the current session
            DELETE FROM public.treatment_session_items WHERE session_id = new_session_id;

            IF session_data->'items' IS NOT NULL AND jsonb_array_length(session_data->'items') > 0 THEN
                FOR item_data IN SELECT * FROM jsonb_array_elements(session_data->'items') LOOP
                    INSERT INTO public.treatment_session_items (
                        session_id,
                        product_id,
                        service_id,
                        quantity
                    )
                    VALUES (
                        new_session_id,
                        (item_data->>'product_id')::uuid,
                        (item_data->>'service_id')::uuid,
                        (item_data->>'quantity')::int
                    );
                END LOOP;
            END IF;
        END LOOP;
    END IF;

    -- Safely delete sessions that were removed in the form
    FOR session_id_to_delete IN
        SELECT id FROM public.treatment_sessions
        WHERE treatment_id = p_treatment_id AND NOT (id = ANY(p_session_ids_to_keep))
    LOOP
        -- Check if the session is referenced in any client assignment
        IF EXISTS (
            SELECT 1 FROM public.client_treatment_sessions
            WHERE prototype_session_id = session_id_to_delete
        ) THEN
            RAISE EXCEPTION 'Cannot delete session with ID % because it is currently assigned to at least one client. Please remove assignments before deleting.', session_id_to_delete;
        END IF;

        -- If not referenced, it's safe to delete
        DELETE FROM public.treatment_session_items WHERE session_id = session_id_to_delete;
        DELETE FROM public.treatment_sessions WHERE id = session_id_to_delete;
    END LOOP;

    -- Return the updated main treatment record
    RETURN updated_treatment;
END;
$$;
