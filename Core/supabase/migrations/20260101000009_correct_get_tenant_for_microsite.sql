-- Corrects the get_tenant_for_microsite function to remove the dependency on tenant_social_networks,
-- as that table lives in the services/tenant database.
DROP FUNCTION IF EXISTS public.get_tenant_for_microsite(TEXT, TEXT, UUID);

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
    v_tenant_record RECORD;
BEGIN
    -- 1. Find the tenant based on platform, country ISO code, and slug
    SELECT 
        t.id,
        t.name,
        t.logo_url,
        t.slug,
        t.description,
        t.country_id,
        t.platform_id
    INTO v_tenant_record
    FROM public.tenants t
    JOIN public.countries c ON t.country_id = c.id
    WHERE lower(c.iso_code) = lower(p_country_iso_code)
      AND lower(t.slug) = lower(p_slug)
      AND t.platform_id = p_platform_id;

    IF v_tenant_record.id IS NULL THEN
        RETURN null;
    END IF;

    -- 2. Return tenant data as JSON. Social networks will be fetched separately.
    RETURN json_build_object(
        'id', v_tenant_record.id,
        'name', v_tenant_record.name,
        'logo_url', v_tenant_record.logo_url,
        'slug', v_tenant_record.slug,
        'description', v_tenant_record.description,
        'country_id', v_tenant_record.country_id,
        'platform_id', v_tenant_record.platform_id
    );
END;
$$;
