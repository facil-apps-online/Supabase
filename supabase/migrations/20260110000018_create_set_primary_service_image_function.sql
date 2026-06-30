DROP FUNCTION IF EXISTS set_primary_service_image(p_service_id uuid, p_image_id uuid);

CREATE OR REPLACE FUNCTION set_primary_service_image(p_service_id uuid, p_image_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Set all images for the service to not primary
  UPDATE public.service_images
  SET is_primary = FALSE
  WHERE service_id = p_service_id;

  -- Set the specified image as primary
  UPDATE public.service_images
  SET is_primary = TRUE
  WHERE id = p_image_id AND service_id = p_service_id;

  -- If the specified image was not found or not associated with the service, it will simply not be set as primary.
  -- No error is raised, as the intent is to ensure only one is primary.
END;
$$;