-- Update check_slug_availability to include platform_id
DROP FUNCTION IF EXISTS public.check_slug_availability(jsonb);
CREATE OR REPLACE FUNCTION public.check_slug_availability(params jsonb)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    p_slug text := params->>'p_slug';
    p_country_id uuid := (params->>'p_country_id')::uuid;
    p_tenant_id uuid := (params->>'p_tenant_id')::uuid;
    p_platform_id uuid;
BEGIN
    -- Get platform_id from the tenant
    SELECT platform_id INTO p_platform_id FROM public.tenants WHERE id = p_tenant_id;
    IF p_platform_id IS NULL THEN
        RAISE EXCEPTION 'Could not determine platform for tenant';
    END IF;

    RETURN NOT EXISTS (
        SELECT 1
        FROM public.tenants
        WHERE slug = p_slug 
          AND country_id = p_country_id
          AND platform_id = p_platform_id
          AND id != p_tenant_id
    );
END;
$$;
COMMENT ON FUNCTION public.check_slug_availability(jsonb) IS 'Checks slug availability within a country and platform, excluding the current tenant.';


-- Update update_tenant_slug to include platform_id check
DROP FUNCTION IF EXISTS public.update_tenant_slug(uuid, text);
CREATE OR REPLACE FUNCTION public.update_tenant_slug(
    p_tenant_id uuid,
    p_slug text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_country_id uuid;
    v_platform_id uuid;
BEGIN
    -- Get the tenant's country and platform
    SELECT country_id, platform_id INTO v_country_id, v_platform_id FROM public.tenants WHERE id = p_tenant_id;

    IF v_platform_id IS NULL OR v_country_id IS NULL THEN
        RAISE EXCEPTION 'Could not determine platform or country for tenant';
    END IF;

    -- Check for slug format
    IF p_slug IS NOT NULL AND (p_slug !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$' OR length(p_slug) <= 2) THEN
        RAISE EXCEPTION 'invalid_slug_format';
    END IF;

    -- Check for uniqueness within the platform and country
    IF p_slug IS NOT NULL AND EXISTS (
        SELECT 1
        FROM public.tenants
        WHERE platform_id = v_platform_id
          AND country_id = v_country_id
          AND slug = p_slug
          AND id != p_tenant_id
    ) THEN
        RAISE EXCEPTION 'slug_already_taken';
    END IF;

    -- Update the tenant's slug
    UPDATE public.tenants
    SET slug = p_slug,
        updated_at = now()
    WHERE id = p_tenant_id;
END;
$$;
COMMENT ON FUNCTION public.update_tenant_slug(uuid, text) IS 'Updates the tenant''s public microsite slug, ensuring it is unique within the country and platform.';
