DROP FUNCTION IF EXISTS get_treatment_images(p_treatment_id uuid);

CREATE OR REPLACE FUNCTION get_treatment_images(p_treatment_id uuid)
RETURNS SETOF public.treatment_images
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  SELECT
    ti.id,
    ti.treatment_id,
    ti.tenant_id,
    ti.image_url,
    ti.is_primary,
    ti.sort_order,
    ti.created_at,
    ti.updated_at,
    ti.google_drive_file_id,
    ti.file_name,
    ti.mime_type,
    ti.file_size
  FROM public.treatment_images ti
  WHERE ti.treatment_id = p_treatment_id
  ORDER BY ti.sort_order ASC, ti.created_at ASC;
END;
$$;