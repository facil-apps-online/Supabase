-- Public RPC to look up tenant logo by portal slug (no auth required)
-- Used by the employee portal login page to show the company logo.

CREATE OR REPLACE FUNCTION public.get_tenant_by_portal_slug(p_slug TEXT)
RETURNS TABLE(tenant_id UUID, logo_url TEXT, tenant_name TEXT)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
    RETURN QUERY
    SELECT t.id, t.logo_url, t.name
    FROM public.tenant_settings ts
    JOIN public.tenants t ON t.id = ts.tenant_id AND t.platform_id = ts.platform_id
    WHERE ts.setting_key = 'portal'
      AND ts.settings_data->>'slug' = p_slug
    LIMIT 1;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_tenant_by_portal_slug(TEXT) TO anon, authenticated;
