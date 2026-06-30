DROP FUNCTION IF EXISTS delete_service_image(p_image_id uuid);

CREATE OR REPLACE FUNCTION delete_service_image(p_image_id uuid)
RETURNS uuid -- Returns the ID of the deleted record
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  deleted_id uuid;
BEGIN
  DELETE FROM public.service_images
  WHERE id = p_image_id
  RETURNING id INTO deleted_id;

  RETURN deleted_id;
END;
$$;