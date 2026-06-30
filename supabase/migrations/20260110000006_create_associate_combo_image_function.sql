DROP FUNCTION IF EXISTS associate_combo_image(p_combo_id uuid, p_google_drive_file_id text);

CREATE OR REPLACE FUNCTION associate_combo_image(p_combo_id uuid, p_google_drive_file_id text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_new_image_id uuid;
  v_tenant_id uuid;
  v_current_max_sort_order INTEGER;
BEGIN
  -- Get tenant_id from combo
  SELECT tenant_id INTO v_tenant_id FROM public.combos WHERE id = p_combo_id;

  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Combo with ID % not found.', p_combo_id;
  END IF;

  -- Get the current maximum sort_order for the given combo
  SELECT COALESCE(MAX(sort_order), -1) INTO v_current_max_sort_order
  FROM public.combo_images
  WHERE combo_id = p_combo_id;

  -- Insert the new image and get its ID
  INSERT INTO public.combo_images (combo_id, tenant_id, image_url, google_drive_file_id, sort_order)
  VALUES (p_combo_id, v_tenant_id, p_google_drive_file_id, p_google_drive_file_id, v_current_max_sort_order + 1)
  RETURNING id INTO v_new_image_id;

  RETURN v_new_image_id;
END;
$$;