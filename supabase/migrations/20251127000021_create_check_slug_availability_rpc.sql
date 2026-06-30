CREATE OR REPLACE FUNCTION public.check_slug_availability(
    p_slug text,
    p_country_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
AS $$
BEGIN
    -- Returns true if slug is available, false if taken.
    RETURN NOT EXISTS (
        SELECT 1
        FROM public.tenants
        WHERE slug = p_slug AND country_id = p_country_id
    );
END;
$$;

COMMENT ON FUNCTION public.check_slug_availability(text, uuid) IS 'Checks if a given slug is available for a tenant within a specific country.';
