DROP FUNCTION IF EXISTS get_service_images(p_service_id uuid);

CREATE OR REPLACE FUNCTION get_service_images(p_service_id uuid)
RETURNS SETOF public.service_images
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  SELECT
    si.id,
    si.service_id,
    si.tenant_id,
    si.google_drive_file_id,
    si.image_url,
    si.file_name,
    si.file_size,
    si.mime_type,
    si.is_primary,
    si.sort_order,
    si.created_at,
    si.updated_at
  FROM public.service_images si
  WHERE si.service_id = p_service_id
  ORDER BY si.sort_order ASC, si.created_at ASC;
END;
$$;