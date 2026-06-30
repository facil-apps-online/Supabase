-- 1. Drop the old functions
DROP FUNCTION IF EXISTS public.get_microsite_data(text, text, uuid);
DROP FUNCTION IF EXISTS public.get_microsite_data(text, text);

-- 2. Create the new function to get branches
CREATE OR REPLACE FUNCTION public.get_branches_for_microsite(
    p_tenant_id UUID
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_branches json;
BEGIN
    -- Find all active branches for that tenant, including their primary photo and social networks
    SELECT json_agg(
        json_build_object(
            'id', b.id,
            'name', b.name,
            'address', b.address,
            'description', b.description,
            'contact_phone', b.contact_phone,
            'whatsapp_phone', b.whatsapp_phone,
            'latitude', b.latitude,
            'longitude', b.longitude,
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
    WHERE b.tenant_id = p_tenant_id AND b.status = 'active' AND b.is_visible_on_microsite = true;

    RETURN COALESCE(v_branches, '[]'::json);
END;
$$;
