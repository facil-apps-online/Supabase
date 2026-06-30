-- Function to get signed consents for a specific appointment
CREATE OR REPLACE FUNCTION get_signed_consents_for_appointment(
    p_tenant_id uuid,
    p_appointment_id uuid
)
RETURNS TABLE (
    id uuid,
    appointment_id uuid,
    client_id uuid,
    professional_id uuid,
    template_id uuid,
    template_name text, -- Added for convenience
    professional_observations text,
    signed_content text,
    signed_at timestamptz,
    created_at timestamptz,
    updated_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY
    SELECT
        sc.id,
        sc.appointment_id,
        sc.client_id,
        sc.professional_id,
        sc.template_id,
        ict.name AS template_name,
        sc.professional_observations,
        sc.signed_content,
        sc.signed_at,
        sc.created_at,
        sc.updated_at
    FROM
        public.signed_consents sc
    JOIN
        public.informed_consent_templates ict ON sc.template_id = ict.id
    WHERE
        sc.tenant_id = p_tenant_id AND sc.appointment_id = p_appointment_id
    ORDER BY
        sc.created_at;
END;
$$;

-- Function to assign a consent template to an appointment
CREATE OR REPLACE FUNCTION assign_consent_to_appointment(
    p_tenant_id uuid,
    p_appointment_id uuid,
    p_template_id uuid
)
RETURNS public.signed_consents
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_client_id uuid;
    v_professional_id uuid;
    new_signed_consent public.signed_consents;
BEGIN
    -- Fetch client_id and professional_id from the appointments table
    SELECT
        a.client_id,
        a.user_id -- Assuming user_id in appointments is the professional_id
    INTO
        v_client_id,
        v_professional_id
    FROM
        public.appointments a
    WHERE
        a.id = p_appointment_id AND a.tenant_id = p_tenant_id;

    -- Check if appointment exists and tenant matches
    IF v_client_id IS NULL THEN
        RAISE EXCEPTION 'Appointment with ID % not found for tenant %', p_appointment_id, p_tenant_id;
    END IF;

    -- Insert a new signed_consents record (initially unsigned)
    INSERT INTO public.signed_consents (
        appointment_id,
        client_id,
        professional_id,
        template_id,
        tenant_id,
        professional_observations, -- Initially null
        signed_content,            -- Initially null
        signed_at                  -- Initially null
    )
    VALUES (
        p_appointment_id,
        v_client_id,
        v_professional_id,
        p_template_id,
        p_tenant_id,
        NULL,
        NULL,
        NULL
    )
    RETURNING * INTO new_signed_consent;

    RETURN new_signed_consent;
END;
$$;
