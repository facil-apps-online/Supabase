DROP FUNCTION IF EXISTS get_product_images(p_product_id uuid);

CREATE OR REPLACE FUNCTION get_product_images(p_product_id uuid)
RETURNS SETOF public.product_images
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  SELECT
    pi.id,
    pi.product_id,
    pi.tenant_id,
    pi.image_url,
    pi.is_primary,
    pi.sort_order,
    pi.created_at,
    pi.updated_at,
    pi.google_drive_file_id,
    pi.file_name,
    pi.mime_type,
    pi.file_size
  FROM public.product_images pi
  WHERE pi.product_id = p_product_id
  ORDER BY pi.sort_order ASC, pi.created_at ASC;
END;
$$;