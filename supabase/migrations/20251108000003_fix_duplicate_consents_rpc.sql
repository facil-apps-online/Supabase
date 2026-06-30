-- Ensures the get_signed_consents_for_attention function returns unique consents
-- by using DISTINCT ON and ordering by the most recent signature.
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
    signature_file_id text
) AS $$
BEGIN
    RETURN QUERY
    SELECT DISTINCT ON (sc.id) -- Ensure one row per signed_consent
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
        cs.google_drive_file_id AS signature_file_id
    FROM
        public.signed_consents sc
    JOIN
        public.informed_consent_templates ct ON sc.template_id = ct.id
    LEFT JOIN
        public.consent_signatures cs ON sc.id = cs.signed_consent_id
    WHERE
        sc.tenant_id = p_tenant_id
        AND sc.attention_id = p_attention_id
        AND (p_attention_service_id IS NULL OR sc.attention_service_id = p_attention_service_id)
    ORDER BY sc.id, cs.created_at DESC; -- Get the most recent signature for each consent
END;
$$ LANGUAGE plpgsql;
