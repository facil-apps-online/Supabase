-- Drop the old, incorrect function if it exists
DROP FUNCTION IF EXISTS public.set_primary_image_for_treatment(uuid, uuid, uuid);

-- Create the new, corrected function
CREATE OR REPLACE FUNCTION public.set_primary_image_for_treatment(p_tenant_id uuid, p_treatment_id uuid, p_image_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    -- Set all images for this treatment to not primary
    UPDATE public.treatment_images
    SET is_primary = FALSE
    WHERE treatment_id = p_treatment_id AND tenant_id = p_tenant_id;

    -- Set the specified image as primary
    UPDATE public.treatment_images
    SET is_primary = TRUE
    WHERE id = p_image_id AND treatment_id = p_treatment_id AND tenant_id = p_tenant_id;

    -- NOTE: The erroneous update to a non-existent 'cover_image_url' column has been removed.
END;
$$;
