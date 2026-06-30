CREATE OR REPLACE FUNCTION sign_consent(
    p_tenant_id UUID,
    p_signed_consent_id UUID,
    p_signature TEXT,
    p_observations TEXT
)
RETURNS VOID AS $$
BEGIN
    UPDATE public.signed_consents
    SET
        signed_content = p_signature,
        professional_observations = p_observations,
        signed_at = NOW()
    WHERE
        id = p_signed_consent_id
        AND tenant_id = p_tenant_id;
END;
$$ LANGUAGE plpgsql;