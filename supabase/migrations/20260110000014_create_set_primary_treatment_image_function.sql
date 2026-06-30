DROP FUNCTION IF EXISTS set_primary_treatment_image(p_treatment_id uuid, p_image_id uuid);

CREATE OR REPLACE FUNCTION set_primary_treatment_image(p_treatment_id uuid, p_image_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Set all images for the treatment to not primary
  UPDATE public.treatment_images
  SET is_primary = FALSE
  WHERE treatment_id = p_treatment_id;

  -- Set the specified image as primary
  UPDATE public.treatment_images
  SET is_primary = TRUE
  WHERE id = p_image_id AND treatment_id = p_treatment_id;

  -- If the specified image was not found or not associated with the treatment, it will simply not be set as primary.
  -- No error is raised, as the intent is to ensure only one is primary.
END;
$$;