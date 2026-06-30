DROP FUNCTION IF EXISTS delete_combo_image(p_image_id uuid);

CREATE OR REPLACE FUNCTION delete_combo_image(p_image_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  deleted_id uuid;
BEGIN
  DELETE FROM public.combo_images
  WHERE id = p_image_id
  RETURNING id INTO deleted_id;

  RETURN deleted_id;
END;
$$;