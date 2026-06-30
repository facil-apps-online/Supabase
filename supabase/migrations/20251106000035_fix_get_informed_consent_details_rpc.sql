DROP FUNCTION IF EXISTS public.get_informed_consent_details(uuid);

CREATE OR REPLACE FUNCTION public.get_informed_consent_details(p_attention_id uuid)
RETURNS TABLE (
    id uuid,
    attention_datetime timestamp with time zone,
    client json,
    service json,
    informed_consent json,
    tenant json
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT
        a.id,
        a.attention_datetime,
        json_build_object('first_name', c.first_name, 'last_name', c.last_name) as client,
        json_build_object('name', s.name) as service,
        json_build_object('text', sc.signed_content, 'signature_file_id', sc.signature_file_id) as informed_consent,
        json_build_object('name', t.name, 'billing_address', t.billing_address, 'tax_id', t.tax_id, 'contact_phone', t.contact_phone, 'logo_url', t.logo_url) as tenant
    FROM
        public.attentions a
    LEFT JOIN
        public.clients c ON a.client_id = c.id
    LEFT JOIN
        public.attention_services aserv ON a.id = aserv.attention_id
    LEFT JOIN
        public.services s ON aserv.service_id = s.id
    LEFT JOIN
        public.signed_consents sc ON a.id = sc.attention_id
    LEFT JOIN
        public.tenants t ON a.tenant_id = t.id
    WHERE
        a.id = p_attention_id;
END;
$$;