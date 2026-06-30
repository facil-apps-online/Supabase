CREATE OR REPLACE FUNCTION delete_signed_consent(
    p_tenant_id UUID,
    p_signed_consent_id UUID
)
RETURNS VOID AS $$
BEGIN
    DELETE FROM public.signed_consents
    WHERE
        id = p_signed_consent_id
        AND tenant_id = p_tenant_id
        AND signed_at IS NULL;
END;
$$ LANGUAGE plpgsql;