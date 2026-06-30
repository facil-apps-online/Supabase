DROP FUNCTION IF EXISTS associate_treatment_image(p_treatment_id uuid, p_google_drive_file_id text);

CREATE OR REPLACE FUNCTION associate_treatment_image(p_treatment_id uuid, p_google_drive_file_id text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_new_image_id uuid;
  v_tenant_id uuid;
  v_current_max_sort_order INTEGER;
BEGIN
  -- Get tenant_id from treatment
  SELECT tenant_id INTO v_tenant_id FROM public.treatments WHERE id = p_treatment_id;

  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Treatment with ID % not found.', p_treatment_id;
  END IF;

  -- Get the current maximum sort_order for the given treatment
  SELECT COALESCE(MAX(sort_order), -1) INTO v_current_max_sort_order
  FROM public.treatment_images
  WHERE treatment_id = p_treatment_id;

  -- Insert the new image and get its ID
  INSERT INTO public.treatment_images (treatment_id, tenant_id, image_url, google_drive_file_id, sort_order)
  VALUES (p_treatment_id, v_tenant_id, p_google_drive_file_id, p_google_drive_file_id, v_current_max_sort_order + 1)
  RETURNING id INTO v_new_image_id;

  RETURN v_new_image_id;
END;
$$;