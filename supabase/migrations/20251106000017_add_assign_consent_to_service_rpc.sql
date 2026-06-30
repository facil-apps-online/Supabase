-- Function to assign a consent template to a specific attention service
CREATE OR REPLACE FUNCTION assign_consent_to_service(
    p_tenant_id uuid,
    p_attention_id uuid,
    p_template_id uuid,
    p_attention_service_id uuid
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
    -- Fetch client_id from the attentions table
    SELECT
        a.client_id
    INTO
        v_client_id
    FROM
        public.attentions a
    WHERE
        a.id = p_attention_id AND a.tenant_id = p_tenant_id;

    -- Check if attention exists and tenant matches
    IF v_client_id IS NULL THEN
        RAISE EXCEPTION 'Attention with ID % not found for tenant %', p_attention_id, p_tenant_id;
    END IF;

    -- Fetch professional_id from the attention_services table
    SELECT
        ats.user_id
    INTO
        v_professional_id
    FROM
        public.attention_services ats
    WHERE
        ats.id = p_attention_service_id AND ats.attention_id = p_attention_id AND ats.tenant_id = p_tenant_id;

    -- Check if attention service exists and tenant/attention matches
    IF v_professional_id IS NULL THEN
        RAISE EXCEPTION 'Attention Service with ID % not found for attention % and tenant %', p_attention_service_id, p_attention_id, p_tenant_id;
    END IF;

    -- Insert a new signed_consents record (initially unsigned)
    INSERT INTO public.signed_consents (
        appointment_id,
        client_id,
        professional_id,
        template_id,
        tenant_id,
        attention_service_id, -- Link to the specific service
        professional_observations, -- Initially null
        signed_content,            -- Initially null
        signed_at                  -- Initially null
    )
    VALUES (
        p_attention_id,
        v_client_id,
        v_professional_id,
        p_template_id,
        p_tenant_id,
        p_attention_service_id,
        NULL,
        NULL,
        NULL
    )
    RETURNING * INTO new_signed_consent;

    RETURN new_signed_consent;
END;
$$;
