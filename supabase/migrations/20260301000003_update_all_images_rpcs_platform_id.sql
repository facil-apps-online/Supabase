-- Migration: update_all_images_rpcs_platform_id
-- Created at: 2026-03-01 00:00:03

--------------------------------------------------------------------------------
-- 1. PRODUCT IMAGES
--------------------------------------------------------------------------------

-- get_product_images
DROP FUNCTION IF EXISTS public.get_product_images(uuid);
CREATE OR REPLACE FUNCTION public.get_product_images(p_platform_id uuid, p_product_id uuid, p_tenant_id uuid)
 RETURNS SETOF product_images
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  RETURN QUERY
  SELECT pi.*
  FROM public.product_images pi
  WHERE pi.product_id = p_product_id 
    AND pi.tenant_id = p_tenant_id
    AND pi.platform_id = p_platform_id
  ORDER BY pi.sort_order ASC, pi.created_at ASC;
END;
$function$;

-- associate_product_image
DROP FUNCTION IF EXISTS public.associate_product_image(uuid, text);
CREATE OR REPLACE FUNCTION public.associate_product_image(p_tenant_id uuid, p_platform_id uuid, p_product_id uuid, p_google_drive_file_id text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_image_id uuid;
  v_is_primary boolean;
BEGIN
  -- Check if any image exists to set primary
  SELECT NOT EXISTS (SELECT 1 FROM public.product_images WHERE product_id = p_product_id AND tenant_id = p_tenant_id) INTO v_is_primary;

  INSERT INTO public.product_images (tenant_id, platform_id, product_id, google_drive_file_id, is_primary, sort_order)
  VALUES (p_tenant_id, p_platform_id, p_product_id, p_google_drive_file_id, v_is_primary, 0)
  RETURNING id INTO v_image_id;

  RETURN v_image_id;
END;
$function$;

-- delete_product_image
DROP FUNCTION IF EXISTS public.delete_product_image(uuid);
CREATE OR REPLACE FUNCTION public.delete_product_image(p_tenant_id uuid, p_platform_id uuid, p_image_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_google_drive_file_id text;
BEGIN
  DELETE FROM public.product_images
  WHERE id = p_image_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id
  RETURNING google_drive_file_id INTO v_google_drive_file_id;

  RETURN v_google_drive_file_id;
END;
$function$;

-- set_primary_product_image
DROP FUNCTION IF EXISTS public.set_primary_product_image(uuid, uuid);
CREATE OR REPLACE FUNCTION public.set_primary_product_image(p_tenant_id uuid, p_platform_id uuid, p_product_id uuid, p_image_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  UPDATE public.product_images
  SET is_primary = (id = p_image_id)
  WHERE product_id = p_product_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;
END;
$function$;

--------------------------------------------------------------------------------
-- 2. COMBO IMAGES
--------------------------------------------------------------------------------

-- get_combo_images
DROP FUNCTION IF EXISTS public.get_combo_images(uuid);
CREATE OR REPLACE FUNCTION public.get_combo_images(p_platform_id uuid, p_combo_id uuid, p_tenant_id uuid)
 RETURNS SETOF combo_images
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  RETURN QUERY
  SELECT ci.*
  FROM public.combo_images ci
  WHERE ci.combo_id = p_combo_id 
    AND ci.tenant_id = p_tenant_id
    AND ci.platform_id = p_platform_id
  ORDER BY ci.sort_order ASC, ci.created_at ASC;
END;
$function$;

-- associate_combo_image
DROP FUNCTION IF EXISTS public.associate_combo_image(uuid, text);
CREATE OR REPLACE FUNCTION public.associate_combo_image(p_tenant_id uuid, p_platform_id uuid, p_combo_id uuid, p_google_drive_file_id text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_image_id uuid;
  v_is_primary boolean;
BEGIN
  SELECT NOT EXISTS (SELECT 1 FROM public.combo_images WHERE combo_id = p_combo_id AND tenant_id = p_tenant_id) INTO v_is_primary;

  INSERT INTO public.combo_images (tenant_id, platform_id, combo_id, google_drive_file_id, is_primary, sort_order)
  VALUES (p_tenant_id, p_platform_id, p_combo_id, p_google_drive_file_id, v_is_primary, 0)
  RETURNING id INTO v_image_id;

  RETURN v_image_id;
END;
$function$;

-- delete_combo_image
DROP FUNCTION IF EXISTS public.delete_combo_image(uuid);
CREATE OR REPLACE FUNCTION public.delete_combo_image(p_tenant_id uuid, p_platform_id uuid, p_image_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_google_drive_file_id text;
BEGIN
  DELETE FROM public.combo_images
  WHERE id = p_image_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id
  RETURNING google_drive_file_id INTO v_google_drive_file_id;

  RETURN v_google_drive_file_id;
END;
$function$;

-- set_primary_combo_image
DROP FUNCTION IF EXISTS public.set_primary_combo_image(uuid, uuid);
CREATE OR REPLACE FUNCTION public.set_primary_combo_image(p_tenant_id uuid, p_platform_id uuid, p_combo_id uuid, p_image_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  UPDATE public.combo_images
  SET is_primary = (id = p_image_id)
  WHERE combo_id = p_combo_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;
END;
$function$;

--------------------------------------------------------------------------------
-- 3. TREATMENT IMAGES
--------------------------------------------------------------------------------

-- get_treatment_images
DROP FUNCTION IF EXISTS public.get_treatment_images(uuid);
CREATE OR REPLACE FUNCTION public.get_treatment_images(p_platform_id uuid, p_treatment_id uuid, p_tenant_id uuid)
 RETURNS SETOF treatment_images
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  RETURN QUERY
  SELECT ti.*
  FROM public.treatment_images ti
  WHERE ti.treatment_id = p_treatment_id 
    AND ti.tenant_id = p_tenant_id
    AND ti.platform_id = p_platform_id
  ORDER BY ti.sort_order ASC, ti.created_at ASC;
END;
$function$;

-- associate_treatment_image
DROP FUNCTION IF EXISTS public.associate_treatment_image(uuid, text);
CREATE OR REPLACE FUNCTION public.associate_treatment_image(p_tenant_id uuid, p_platform_id uuid, p_treatment_id uuid, p_google_drive_file_id text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_image_id uuid;
  v_is_primary boolean;
BEGIN
  SELECT NOT EXISTS (SELECT 1 FROM public.treatment_images WHERE treatment_id = p_treatment_id AND tenant_id = p_tenant_id) INTO v_is_primary;

  INSERT INTO public.treatment_images (tenant_id, platform_id, treatment_id, google_drive_file_id, is_primary, sort_order)
  VALUES (p_tenant_id, p_platform_id, p_treatment_id, p_google_drive_file_id, v_is_primary, 0)
  RETURNING id INTO v_image_id;

  RETURN v_image_id;
END;
$function$;

-- delete_treatment_image
DROP FUNCTION IF EXISTS public.delete_treatment_image(uuid);
CREATE OR REPLACE FUNCTION public.delete_treatment_image(p_tenant_id uuid, p_platform_id uuid, p_image_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_google_drive_file_id text;
BEGIN
  DELETE FROM public.treatment_images
  WHERE id = p_image_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id
  RETURNING google_drive_file_id INTO v_google_drive_file_id;

  RETURN v_google_drive_file_id;
END;
$function$;

-- set_primary_treatment_image
DROP FUNCTION IF EXISTS public.set_primary_treatment_image(uuid, uuid);
CREATE OR REPLACE FUNCTION public.set_primary_treatment_image(p_tenant_id uuid, p_platform_id uuid, p_treatment_id uuid, p_image_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  UPDATE public.treatment_images
  SET is_primary = (id = p_image_id)
  WHERE treatment_id = p_treatment_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;
END;
$function$;

--------------------------------------------------------------------------------
-- 4. SERVICE IMAGES
--------------------------------------------------------------------------------

-- get_service_images
DROP FUNCTION IF EXISTS public.get_service_images(uuid);
CREATE OR REPLACE FUNCTION public.get_service_images(p_platform_id uuid, p_service_id uuid, p_tenant_id uuid)
 RETURNS SETOF service_images
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  RETURN QUERY
  SELECT si.*
  FROM public.service_images si
  WHERE si.service_id = p_service_id 
    AND si.tenant_id = p_tenant_id
    AND si.platform_id = p_platform_id
  ORDER BY si.sort_order ASC, si.created_at ASC;
END;
$function$;

-- associate_service_image
DROP FUNCTION IF EXISTS public.associate_service_image(uuid, text);
CREATE OR REPLACE FUNCTION public.associate_service_image(p_tenant_id uuid, p_platform_id uuid, p_service_id uuid, p_google_drive_file_id text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_image_id uuid;
  v_is_primary boolean;
BEGIN
  SELECT NOT EXISTS (SELECT 1 FROM public.service_images WHERE service_id = p_service_id AND tenant_id = p_tenant_id) INTO v_is_primary;

  INSERT INTO public.service_images (tenant_id, platform_id, service_id, google_drive_file_id, is_primary, sort_order)
  VALUES (p_tenant_id, p_platform_id, p_service_id, p_google_drive_file_id, v_is_primary, 0)
  RETURNING id INTO v_image_id;

  RETURN v_image_id;
END;
$function$;

-- delete_service_image
DROP FUNCTION IF EXISTS public.delete_service_image(uuid);
CREATE OR REPLACE FUNCTION public.delete_service_image(p_tenant_id uuid, p_platform_id uuid, p_image_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_google_drive_file_id text;
BEGIN
  DELETE FROM public.service_images
  WHERE id = p_image_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id
  RETURNING google_drive_file_id INTO v_google_drive_file_id;

  RETURN v_google_drive_file_id;
END;
$function$;

-- set_primary_service_image
DROP FUNCTION IF EXISTS public.set_primary_service_image(uuid, uuid);
CREATE OR REPLACE FUNCTION public.set_primary_service_image(p_tenant_id uuid, p_platform_id uuid, p_service_id uuid, p_image_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  UPDATE public.service_images
  SET is_primary = (id = p_image_id)
  WHERE service_id = p_service_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;
END;
$function$;
