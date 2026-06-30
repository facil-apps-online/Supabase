DROP FUNCTION IF EXISTS set_primary_product_image(p_product_id uuid, p_image_id uuid);

CREATE OR REPLACE FUNCTION set_primary_product_image(p_product_id uuid, p_image_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Set all images for the product to not primary
  UPDATE public.product_images
  SET is_primary = FALSE
  WHERE product_id = p_product_id;

  -- Set the specified image as primary
  UPDATE public.product_images
  SET is_primary = TRUE
  WHERE id = p_image_id AND product_id = p_product_id;

  -- If the specified image was not found or not associated with the product, it will simply not be set as primary.
  -- No error is raised, as the intent is to ensure only one is primary.
END;
$$;