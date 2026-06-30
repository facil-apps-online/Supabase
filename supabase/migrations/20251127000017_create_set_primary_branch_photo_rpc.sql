CREATE OR REPLACE FUNCTION public.set_primary_branch_photo(
    p_tenant_id uuid,
    p_branch_id uuid,
    p_photo_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    -- First, ensure the photo belongs to the tenant and branch
    IF NOT EXISTS (
        SELECT 1 FROM public.branch_photos
        WHERE id = p_photo_id AND branch_id = p_branch_id AND tenant_id = p_tenant_id
    ) THEN
        RAISE EXCEPTION 'Photo not found or permission denied';
    END IF;

    -- Set all other photos for this branch to not be primary
    UPDATE public.branch_photos
    SET is_primary = false
    WHERE branch_id = p_branch_id
      AND tenant_id = p_tenant_id
      AND is_primary = true;

    -- Set the specified photo as primary
    UPDATE public.branch_photos
    SET is_primary = true,
        updated_at = now()
    WHERE id = p_photo_id;
END;
$$;

COMMENT ON FUNCTION public.set_primary_branch_photo(uuid, uuid, uuid) IS 'Sets a specific photo as the primary one for a branch, and unsets any previous primary photo.';
