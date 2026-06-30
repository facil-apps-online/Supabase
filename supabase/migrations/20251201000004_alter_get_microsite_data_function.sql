CREATE OR REPLACE FUNCTION public.get_microsite_data(
    p_country_iso_code text,
    p_slug text,
    p_platform_id uuid
)
RETURNS json
LANGUAGE plpgsql
AS $$
DECLARE
    v_tenant record;
    v_branches json;
BEGIN
    -- 1. Find the tenant based on platform, country ISO code, and slug
    SELECT t.id, t.name, t.logo_url, t.slug, t.country_id, t.platform_id INTO v_tenant
    FROM public.tenants t
    JOIN public.countries c ON t.country_id = c.id
    WHERE lower(c.iso_code) = lower(p_country_iso_code)
      AND t.slug = p_slug
      AND t.platform_id = p_platform_id;

    IF v_tenant IS NULL THEN
        RETURN json_build_object('error', 'Tenant not found');
    END IF;

    -- 2. Find all active branches for that tenant, including their primary photo
    SELECT json_agg(
        json_build_object(
            'id', b.id,
            'name', b.name,
            'address', b.address,
            'contact_phone', b.contact_phone,
            'whatsapp_phone', b.whatsapp_phone,
            'primary_photo_gdrive_id', (
                SELECT bp.google_drive_file_id
                FROM public.branch_photos bp
                WHERE bp.branch_id = b.id AND bp.is_primary = true
                LIMIT 1
            )
        )
    )
    INTO v_branches
    FROM public.branches b
    WHERE b.tenant_id = v_tenant.id AND b.status = 'active';

    -- 3. Return the combined data
    RETURN json_build_object(
        'tenant', row_to_json(v_tenant),
        'branches', COALESCE(v_branches, '[]'::json)
    );
END;
$$;

COMMENT ON FUNCTION public.get_microsite_data(text, text, uuid) IS 'Fetches all public data for a tenant''s microsite based on platform, country, and slug.';