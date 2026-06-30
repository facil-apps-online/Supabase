-- Function to get signed consents for a specific attention, optionally filtered by attention service
CREATE OR REPLACE FUNCTION get_signed_consents_for_attention(
    p_tenant_id uuid,
    p_attention_id uuid,
    p_attention_service_id uuid DEFAULT NULL
)
RETURNS TABLE (
    id uuid,
    attention_id uuid,
    client_id uuid,
    professional_id uuid,
    template_id uuid,
    template_name text,
    professional_observations text,
    signed_content text,
    signed_at timestamptz,
    created_at timestamptz,
    updated_at timestamptz,
    attention_service_id uuid
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY
    SELECT
        sc.id,
        sc.attention_id, -- Renamed column
        sc.client_id,
        sc.professional_id,
        sc.template_id,
        ict.name AS template_name,
        sc.professional_observations,
        sc.signed_content,
        sc.signed_at,
        sc.created_at,
        sc.updated_at,
        sc.attention_service_id
    FROM
        public.signed_consents sc
    JOIN
        public.informed_consent_templates ict ON sc.template_id = ict.id
    WHERE
        sc.tenant_id = p_tenant_id
        AND sc.attention_id = p_attention_id
        AND (p_attention_service_id IS NULL OR sc.attention_service_id = p_attention_service_id)
    ORDER BY
        sc.created_at;
END;
$$;

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
        attention_id, -- Renamed column
        client_id,
        professional_id,
        template_id,
        tenant_id,
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
        p_attention_service_id,
        NULL,
        NULL,
        NULL
    )
    RETURNING * INTO new_signed_consent;

    RETURN new_signed_consent;
END;
$$;
