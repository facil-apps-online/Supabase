-- Create upsert_tenant_integration RPC in Core (Updated with platform_id)
-- Timestamp: 20260119000003

CREATE OR REPLACE FUNCTION public.upsert_tenant_integration(
    p_tenant_id uuid,
    p_platform_id uuid, -- Added platform_id parameter
    p_provider_slug text,
    p_encrypted_credentials text,
    p_nonce text,
    p_environment text,
    p_user_role text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    -- Validation
    IF p_environment NOT IN ('test', 'production') THEN
        RAISE EXCEPTION 'Invalid environment. Must be ''test'' or ''production''.';
    END IF;

    -- Upsert logic
    INSERT INTO public.tenant_integrations (
        tenant_id,
        platform_id, -- Insert platform_id
        provider,
        encrypted_credentials,
        nonce,
        environment,
        is_active,
        updated_at,
        created_at
    )
    VALUES (
        p_tenant_id,
        p_platform_id,
        p_provider_slug,
        p_encrypted_credentials,
        p_nonce,
        p_environment,
        true,
        NOW(),
        NOW()
    )
    ON CONFLICT (tenant_id, provider, environment)
    DO UPDATE SET
        encrypted_credentials = EXCLUDED.encrypted_credentials,
        nonce = EXCLUDED.nonce,
        is_active = TRUE,
        updated_at = NOW();
        -- We don't typically update platform_id on conflict as it shouldn't change for a tenant
END;
$$;