CREATE OR REPLACE FUNCTION public.delete_branch_photo(
    p_branch_id uuid,  -- Changed order
    p_photo_id uuid,    -- Changed order
    p_tenant_id uuid
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_google_drive_file_id text;
    v_is_primary boolean;
BEGIN
    -- Check if the photo exists, belongs to the tenant/branch, and get its details
    SELECT google_drive_file_id, is_primary
    INTO v_google_drive_file_id, v_is_primary
    FROM public.branch_photos
    WHERE id = p_photo_id AND branch_id = p_branch_id AND tenant_id = p_tenant_id;

    IF v_google_drive_file_id IS NULL THEN
        RAISE EXCEPTION 'Photo not found or permission denied';
    END IF;

    -- If it's the primary photo, check if there are other photos for the branch.
    -- If there are, we might need to automatically set a new primary, or prevent deletion.
    -- Correction: If it's the primary photo AND there are other photos, prevent deletion.
    IF v_is_primary AND (SELECT COUNT(*) FROM public.branch_photos WHERE branch_id = p_branch_id AND id != p_photo_id) > 0 THEN
        RAISE EXCEPTION 'Cannot delete primary photo if other photos exist. Set another photo as primary first.';
    END IF;


    -- Delete the record from the database
    DELETE FROM public.branch_photos
    WHERE id = p_photo_id;

    -- Return the Google Drive File ID so the edge function can delete the file from Drive
    RETURN v_google_drive_file_id;
END;
$$;

COMMENT ON FUNCTION public.delete_branch_photo(uuid, uuid, uuid) IS 'Deletes a branch photo record and returns its Google Drive File ID for external deletion.';