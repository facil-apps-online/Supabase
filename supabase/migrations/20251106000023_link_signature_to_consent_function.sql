CREATE OR REPLACE FUNCTION link_signature_to_consent(
    p_tenant_id UUID,
    p_signed_consent_id UUID,
    p_observations TEXT
)
RETURNS VOID AS $$
BEGIN
    UPDATE public.signed_consents
    SET
        professional_observations = p_observations,
        signed_at = NOW()
    WHERE
        id = p_signed_consent_id
        AND tenant_id = p_tenant_id;
END;
$$ LANGUAGE plpgsql;