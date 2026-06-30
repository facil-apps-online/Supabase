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
BEGIN
    -- Get the tenant's country
    SELECT country_id INTO v_country_id FROM public.tenants WHERE id = p_tenant_id;

    -- Check for slug format
    IF p_slug IS NOT NULL AND (p_slug !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$' OR length(p_slug) <= 2) THEN
        RAISE EXCEPTION 'invalid_slug_format';
    END IF;

    -- Check for uniqueness within the country
    IF p_slug IS NOT NULL AND EXISTS (
        SELECT 1
        FROM public.tenants
        WHERE country_id = v_country_id
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

COMMENT ON FUNCTION public.update_tenant_slug(uuid, text) IS 'Updates the tenant''s public microsite slug, ensuring it is unique within the country.';
