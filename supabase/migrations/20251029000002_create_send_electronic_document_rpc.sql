CREATE OR REPLACE FUNCTION public.send_electronic_document(
    p_tenant_id UUID,
    p_document_id UUID, -- Assuming this is an invoice ID from public.invoices
    p_provider_slug TEXT,
    p_document_type TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_provider_config RECORD;
    v_tenant_integration RECORD;
    v_invoice_data JSONB;
    v_request_body JSONB;
    v_request_headers JSONB;
    v_request_url TEXT;
    v_response_content JSONB;
    v_http_method TEXT;
    v_auth_token TEXT;
    v_dataico_account_id TEXT;
    v_decrypted_credentials JSONB;
    v_service_role_key TEXT;
    v_supabase_url TEXT;
    v_edge_function_url TEXT;
    v_edge_function_response JSONB;
BEGIN
    -- 1. Fetch provider configuration from integration_providers
    SELECT
        ip.endpoints,
        ip.config_schema,
        ip.api_schema,
        ihm.method AS http_method,
        ibf.format AS body_format,
        iam.method AS auth_method,
        ip.http_headers,
        ip.authentication_config
    INTO v_provider_config
    FROM public.integration_providers ip
    JOIN public.integration_http_methods ihm ON ip.http_method_id = ihm.id
    JOIN public.integration_body_formats ibf ON ip.body_format_id = ibf.id
    JOIN public.integration_auth_methods iam ON ip.auth_method_id = iam.id
    WHERE ip.slug = p_provider_slug;

    IF v_provider_config.endpoints IS NULL THEN
        RAISE EXCEPTION 'Provider configuration not found for slug: %', p_provider_slug;
    END IF;

    -- 2. Fetch tenant-specific integration credentials
    SELECT encrypted_credentials, nonce, environment
    INTO v_tenant_integration
    FROM public.tenant_integrations
    WHERE tenant_id = p_tenant_id AND provider = p_provider_slug AND is_active = TRUE;

    IF v_tenant_integration.encrypted_credentials IS NULL THEN
        RAISE EXCEPTION 'Active tenant integration credentials not found for tenant % and provider %', p_tenant_id, p_provider_slug;
    END IF;

    -- 3. Fetch Glamtica invoice data
    SELECT to_jsonb(i.*) || jsonb_build_object('items', (SELECT jsonb_agg(ii.*) FROM public.invoice_items ii WHERE ii.invoice_id = i.id))
    INTO v_invoice_data
    FROM public.invoices i
    WHERE i.id = p_document_id AND i.tenant_id = p_tenant_id;

    IF v_invoice_data IS NULL THEN
        RAISE EXCEPTION 'Invoice data not found for document ID: %', p_document_id;
    END IF;

    -- 4. Prepare request URL
    v_request_url := v_provider_config.endpoints->>v_tenant_integration.environment;
    IF v_request_url IS NULL THEN
        RAISE EXCEPTION 'Endpoint URL not found for environment %', v_tenant_integration.environment;
    END IF;

    -- 5. Call an Edge Function to handle data mapping, decryption, and external API call
    -- This Edge Function will receive:
    -- - Glamtica invoice data (v_invoice_data)
    -- - Provider's api_schema (v_provider_config.api_schema)
    -- - Provider's http_headers (v_provider_config.http_headers)
    -- - Tenant's encrypted credentials (v_tenant_integration.encrypted_credentials, v_tenant_integration.nonce)
    -- - Dataico_account_id and Auth-token from config_schema (extracted from decrypted credentials)
    -- - Target API URL (v_request_url)
    -- - HTTP Method (v_provider_config.http_method)

    -- Get Supabase URL and Service Role Key for Edge Function invocation
    SELECT value INTO v_supabase_url FROM private.secrets WHERE key = 'supabase_url';
    SELECT value INTO v_service_role_key FROM private.secrets WHERE key = 'service_role_key';

    v_edge_function_url := v_supabase_url || '/functions/v1/map-and-send-dataico'; -- Name of the new Edge Function

    SELECT content INTO v_edge_function_response FROM net.http_post(
        url:= v_edge_function_url,
        body:= jsonb_build_object(
            'tenant_id', p_tenant_id,
            'document_id', p_document_id,
            'glamtica_invoice_data', v_invoice_data,
            'provider_api_schema', v_provider_config.api_schema,
            'provider_http_headers', v_provider_config.http_headers,
            'provider_endpoints', v_provider_config.endpoints,
            'tenant_encrypted_credentials', v_tenant_integration.encrypted_credentials,
            'tenant_nonce', v_tenant_integration.nonce,
            'tenant_environment', v_tenant_integration.environment,
            'http_method', v_provider_config.http_method,
            'body_format', v_provider_config.body_format
        ),
        headers:= jsonb_build_object(
            'Content-Type', 'application/json',
            'Authorization', 'Bearer ' || v_service_role_key -- Authorize Edge Function call
        )
    );

    -- 6. Handle response from Edge Function and update invoice status
    IF (v_edge_function_response->>'success')::BOOLEAN THEN
        -- Update invoice status, provider reference, etc.
        UPDATE public.invoices
        SET
            status = 'sent_to_dataico', -- Or a more specific status
            provider_reference_id = v_edge_function_response->>'dataico_document_id',
            -- Add other fields as needed from the response
            updated_at = NOW()
        WHERE id = p_document_id;

        RETURN jsonb_build_object('success', TRUE, 'message', 'Document sent successfully to Dataico.', 'dataico_response', v_edge_function_response);
    ELSE
        -- Log error and update invoice status
        UPDATE public.invoices
        SET
            status = 'failed_dataico_send',
            error_message = v_edge_function_response->>'error',
            updated_at = NOW()
        WHERE id = p_document_id;

        RAISE EXCEPTION 'Failed to send document to Dataico: %', v_edge_function_response->>'error';
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        -- Log any unexpected errors
        RAISE EXCEPTION 'Error in send_electronic_document: %', SQLERRM;
END;
$$;
