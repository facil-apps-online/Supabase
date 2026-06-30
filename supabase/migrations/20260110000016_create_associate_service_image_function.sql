DROP FUNCTION IF EXISTS associate_service_image(p_service_id uuid, p_google_drive_file_id text);

CREATE OR REPLACE FUNCTION associate_service_image(p_service_id uuid, p_google_drive_file_id text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_new_image_id uuid;
  v_tenant_id uuid;
  v_current_max_sort_order INTEGER;
BEGIN
  -- Get tenant_id from service
  SELECT tenant_id INTO v_tenant_id FROM public.services WHERE id = p_service_id;

  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Service with ID % not found.', p_service_id;
  END IF;

  -- Get the current maximum sort_order for the given service
  SELECT COALESCE(MAX(sort_order), -1) INTO v_current_max_sort_order
  FROM public.service_images
  WHERE service_id = p_service_id;

  -- Insert the new image and get its ID
  INSERT INTO public.service_images (service_id, tenant_id, image_url, google_drive_file_id, sort_order)
  VALUES (p_service_id, v_tenant_id, p_google_drive_file_id, p_google_drive_file_id, v_current_max_sort_order + 1)
  RETURNING id INTO v_new_image_id;

  RETURN v_new_image_id;
END;
$$;