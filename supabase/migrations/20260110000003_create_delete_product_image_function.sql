DROP FUNCTION IF EXISTS delete_product_image(p_image_id uuid);

CREATE OR REPLACE FUNCTION delete_product_image(p_image_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  DELETE FROM public.product_images
  WHERE id = p_image_id;
END;
$$;