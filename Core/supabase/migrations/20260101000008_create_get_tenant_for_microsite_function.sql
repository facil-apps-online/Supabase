CREATE OR REPLACE FUNCTION public.get_tenant_for_microsite(
    p_country_iso_code TEXT,
    p_slug TEXT,
    p_platform_id UUID
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_tenant json;
    v_tenant_id uuid;
BEGIN
    -- 1. Find the tenant based on platform, country ISO code, and slug
    SELECT t.id INTO v_tenant_id
    FROM public.tenants t
    JOIN public.countries c ON t.country_id = c.id
    WHERE lower(c.iso_code) = lower(p_country_iso_code)
      AND t.slug = p_slug
      AND t.platform_id = p_platform_id;

    IF v_tenant_id IS NULL THEN
        -- Return null if not found, the edge function will handle the 404
        RETURN null;
    END IF;

    -- 2. Get tenant data including social networks
    SELECT json_build_object(
        'id', t.id,
        'name', t.name,
        'logo_url', t.logo_url,
        'slug', t.slug,
        'description', t.description,
        'country_id', t.country_id,
        'platform_id', t.platform_id,
        'social_networks', (
            SELECT COALESCE(json_agg(
                json_build_object('network', tsn.network, 'url', tsn.url)
            ), '[]'::json)
            FROM public.tenant_social_networks tsn
            WHERE tsn.tenant_id = v_tenant_id
        )
    )
    INTO v_tenant
    FROM public.tenants t
    WHERE t.id = v_tenant_id;

    RETURN v_tenant;
END;
$$;
