DROP FUNCTION IF EXISTS public.link_signature_to_consent(uuid, uuid, text);

CREATE OR REPLACE FUNCTION public.link_signature_to_consent(
    p_tenant_id UUID,
    p_signed_consent_id UUID,
    p_observations TEXT,
    p_form_data JSONB
)
RETURNS VOID AS $$
BEGIN
    UPDATE public.signed_consents
    SET
        professional_observations = p_observations,
        signed_at = NOW(),
        form_data = p_form_data
    WHERE
        id = p_signed_consent_id
        AND tenant_id = p_tenant_id;
END;
$$ LANGUAGE plpgsql;