DROP FUNCTION IF EXISTS get_combo_images(p_combo_id uuid);

CREATE OR REPLACE FUNCTION get_combo_images(p_combo_id uuid)
RETURNS SETOF public.combo_images
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  SELECT
    ci.id,
    ci.combo_id,
    ci.google_drive_file_id,
    ci.image_url,
    ci.file_name,
    ci.file_size,
    ci.mime_type,
    ci.is_primary,
    ci.sort_order,
    ci.created_at,
    ci.updated_at,
    ci.tenant_id
  FROM public.combo_images ci
  WHERE ci.combo_id = p_combo_id
  ORDER BY ci.sort_order ASC, ci.created_at ASC;
END;
$$;