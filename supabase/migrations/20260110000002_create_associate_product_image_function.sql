DROP FUNCTION IF EXISTS associate_product_image(p_product_id uuid, p_google_drive_file_id text);

CREATE OR REPLACE FUNCTION associate_product_image(p_product_id uuid, p_google_drive_file_id text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_new_image_id uuid;
  v_tenant_id uuid;
  v_current_max_sort_order INTEGER;
BEGIN
  -- Get tenant_id from product
  SELECT tenant_id INTO v_tenant_id FROM public.products WHERE id = p_product_id;

  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Product with ID % not found.', p_product_id;
  END IF;

  -- Get the current maximum sort_order for the given product
  SELECT COALESCE(MAX(sort_order), -1) INTO v_current_max_sort_order
  FROM public.product_images
  WHERE product_id = p_product_id;

  -- Insert the new image and get its ID
  INSERT INTO public.product_images (product_id, tenant_id, image_url, google_drive_file_id, sort_order)
  VALUES (p_product_id, v_tenant_id, p_google_drive_file_id, p_google_drive_file_id, v_current_max_sort_order + 1)
  RETURNING id INTO v_new_image_id;

  RETURN v_new_image_id;
END;
$$;