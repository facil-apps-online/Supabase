DROP FUNCTION IF EXISTS update_service_images_order(p_images_data jsonb);

CREATE OR REPLACE FUNCTION update_service_images_order(p_images_data jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE public.service_images as si
  SET
    sort_order = (data.value->>'sort_order')::integer
  FROM jsonb_array_elements(p_images_data) as data
  WHERE si.id = (data.value->>'id')::uuid;
END;
$$;