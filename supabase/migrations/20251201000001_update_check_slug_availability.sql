CREATE OR REPLACE FUNCTION public.check_slug_availability(p_slug text, p_country_id uuid, p_tenant_id uuid, p_platform_id uuid)
RETURNS boolean
LANGUAGE plpgsql
AS $$
BEGIN
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