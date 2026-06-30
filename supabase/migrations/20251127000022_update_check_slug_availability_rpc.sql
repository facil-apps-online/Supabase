-- Drop the old function signature
DROP FUNCTION IF EXISTS public.check_slug_availability(text, uuid, uuid);

-- Re-create the function to accept a single JSONB parameter
CREATE OR REPLACE FUNCTION public.check_slug_availability(params jsonb)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    p_slug text := params->>'p_slug';
    p_country_id uuid := (params->>'p_country_id')::uuid;
    p_tenant_id uuid := (params->>'p_tenant_id')::uuid;
BEGIN
    -- Returns true if slug is available, false if taken by ANOTHER tenant in the same country.
    RETURN NOT EXISTS (
        SELECT 1
        FROM public.tenants
        WHERE slug = p_slug 
          AND country_id = p_country_id
          AND id != p_tenant_id
    );
END;
$$;

COMMENT ON FUNCTION public.check_slug_availability(jsonb) IS 'Checks if a given slug is available for a tenant within a specific country, excluding the tenant''s own current slug, by accepting parameters as a JSONB object.';