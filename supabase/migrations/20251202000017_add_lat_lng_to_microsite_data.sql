-- Migration to add latitude and longitude to the branch data in the get_microsite_data RPC function

CREATE OR REPLACE FUNCTION public.get_microsite_data(
    p_country_iso_code text,
    p_slug text,
    p_platform_id uuid
)
RETURNS json
LANGUAGE plpgsql
AS $$
DECLARE
    v_tenant json;
    v_branches json;
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
        RETURN json_build_object('error', 'Tenant not found');
    END IF;

    -- 2. Get tenant data including social networks
    SELECT json_build_object(
        'id', t.id,
        'name', t.name,
        'logo_url', t.logo_url,
        'slug', t.slug,
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

    -- 3. Find all active branches for that tenant, including their primary photo and social networks
    SELECT json_agg(
        json_build_object(
            'id', b.id,
            'name', b.name,
            'address', b.address,
            'contact_phone', b.contact_phone,
            'whatsapp_phone', b.whatsapp_phone,
            'latitude', b.latitude, -- Added
            'longitude', b.longitude, -- Added
            'primary_photo_gdrive_id', (
                SELECT bp.google_drive_file_id
                FROM public.branch_photos bp
                WHERE bp.branch_id = b.id AND bp.is_primary = true
                LIMIT 1
            ),
            'social_networks', (
                SELECT COALESCE(json_agg(
                    json_build_object('network', bsn.network, 'url', bsn.url)
                ), '[]'::json)
                FROM public.branch_social_networks bsn
                WHERE bsn.branch_id = b.id
            )
        )
    )
    INTO v_branches
    FROM public.branches b
    WHERE b.tenant_id = v_tenant_id AND b.status = 'active';

    -- 4. Return the combined data
    RETURN json_build_object(
        'tenant', v_tenant,
        'branches', COALESCE(v_branches, '[]'::json)
    );
END;
$$;

COMMENT ON FUNCTION public.get_microsite_data(text, text, uuid) IS 'Fetches all public data for a tenant''s microsite, including social networks and branch coordinates.';
