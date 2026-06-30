CREATE OR REPLACE FUNCTION public.assign_treatment_to_client(
    p_tenant_id uuid,
    p_client_id uuid,
    p_prototype_id uuid, -- ID del tratamiento maestro
    p_custom_name text, -- Nombre personalizado del tratamiento para el cliente
    p_payment_type text,
    p_custom_final_price numeric(10, 2),
    p_start_date date,
    p_sessions jsonb -- Array de objetos de sesión con sus ítems
)
RETURNS public.client_treatments
LANGUAGE plpgsql
AS $$
DECLARE
    v_treatment public.treatments;
    v_new_client_treatment public.client_treatments;
    session_data jsonb;
    v_client_treatment_session_id uuid;
    item_data jsonb;
BEGIN
    -- 1. Obtener detalles del prototipo de tratamiento
    -- Esto es útil para validación o si se necesitan otros datos del maestro.
    SELECT * INTO v_treatment FROM public.treatments WHERE id = p_prototype_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Treatment prototype not found.';
    END IF;

    -- 2. Crear el registro principal en client_treatments
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
        p_custom_name, -- Usar el nombre personalizado
        'active',
        p_start_date,
        p_custom_final_price,
        p_payment_type
    )
    RETURNING * INTO v_new_client_treatment;

    -- 3. Crear client_treatment_sessions a partir del array JSON
    IF NOT jsonb_typeof(p_sessions) = 'array' THEN
        RAISE EXCEPTION 'p_sessions must be an array of session objects.';
    END IF;

    FOR session_data IN SELECT * FROM jsonb_array_elements(p_sessions)
    LOOP
        INSERT INTO public.client_treatment_sessions (
            client_treatment_id,
            -- prototype_session_id, -- Considerar si es necesario mantener esta referencia
            session_number,
            name,
            description, -- Nuevo: Insertar descripción de la sesión
            payment_due_amount, -- Usar payment_amount del frontend para payment_due_amount
            payment_due_percentage, -- Nuevo: Insertar porcentaje de pago
            fixed_payment_amount -- Nuevo: Insertar monto fijo de pago
        )
        VALUES (
            v_new_client_treatment.id,
            -- (session_data->>'id')::uuid, -- Si 'id' en session_data es el prototype_session_id
            (session_data->>'session_number')::integer,
            session_data->>'name',
            session_data->>'description',
            (session_data->>'payment_amount')::numeric,
            (session_data->>'payment_percentage')::numeric,
            (session_data->>'fixed_payment_amount')::numeric
        )
        RETURNING id INTO v_client_treatment_session_id;

        -- Insertar ítems asociados para esta sesión
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
