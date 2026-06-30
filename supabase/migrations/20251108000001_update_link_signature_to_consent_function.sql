CREATE OR REPLACE FUNCTION public.link_signature_to_consent(
    p_tenant_id uuid,
    p_signed_consent_id uuid,
    p_observations text,
    p_form_data jsonb,
    p_signed_content text
)
RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
    UPDATE public.signed_consents
    SET
        professional_observations = p_observations,
        signed_at = NOW(),
        form_data = p_form_data,
        signed_content = p_signed_content
    WHERE
        id = p_signed_consent_id
        AND tenant_id = p_tenant_id;
END;
$function$