-- Fixes a bug in get_signed_consents_for_attention where raw_user_meta_data was not being cast to jsonb
DROP FUNCTION IF EXISTS get_signed_consents_for_attention(uuid, uuid, uuid);

CREATE OR REPLACE FUNCTION get_signed_consents_for_attention(
    p_tenant_id uuid,
    p_attention_id uuid,
    p_attention_service_id uuid DEFAULT NULL
)
RETURNS TABLE(
    id uuid,
    attention_id uuid,
    client_id uuid,
    professional_id uuid,
    template_id uuid,
    template_name text,
    template_content text,
    professional_observations text,
    signed_content text,
    signed_at timestamptz,
    created_at timestamptz,
    updated_at timestamptz,
    attention_service_id uuid,
    client_name text,
    client_document_type text,
    client_document_number text,
    professional_name text
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        sc.id,
        sc.attention_id,
        sc.client_id,
        sc.professional_id,
        sc.template_id,
        ct.name AS template_name,
        ct.content AS template_content,
        sc.professional_observations,
        sc.signed_content,
        sc.signed_at,
        sc.created_at,
        sc.updated_at,
        sc.attention_service_id,
        cl.name AS client_name,
        dt.name AS client_document_type,
        cl.document_number AS client_document_number,
        (u.raw_user_meta_data::jsonb->>'first_name' || ' ' || u.raw_user_meta_data::jsonb->>'last_name') AS professional_name
    FROM
        public.signed_consents sc
    JOIN
        public.informed_consent_templates ct ON sc.template_id = ct.id
    LEFT JOIN
        public.clients cl ON sc.client_id = cl.id
    LEFT JOIN
        public.document_types dt ON cl.document_type_id = dt.id
    LEFT JOIN
        auth.users u ON sc.professional_id = u.id
    WHERE
        sc.tenant_id = p_tenant_id
        AND sc.attention_id = p_attention_id
        AND (p_attention_service_id IS NULL OR sc.attention_service_id = p_attention_service_id);
END;
$$ LANGUAGE plpgsql;
