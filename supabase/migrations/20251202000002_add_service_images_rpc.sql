-- RPC to get images for a specific service
CREATE OR REPLACE FUNCTION public.get_service_images(p_service_id uuid)
RETURNS SETOF public.service_images
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT *
    FROM public.service_images
    WHERE service_id = p_service_id
    ORDER BY is_primary DESC, sort_order ASC;
END;
$$;

-- RPC to add an image to a service from a URL
CREATE OR REPLACE FUNCTION public.add_service_image(
    p_service_id uuid,
    p_image_url text
)
RETURNS public.service_images
LANGUAGE plpgsql
AS $$
DECLARE
    new_image public.service_images;
    v_tenant_id uuid;
BEGIN
    SELECT tenant_id INTO v_tenant_id FROM public.services WHERE id = p_service_id;

    INSERT INTO public.service_images (service_id, image_url, tenant_id, google_drive_file_id)
    VALUES (p_service_id, p_image_url, v_tenant_id, 'from_url_' || gen_random_uuid()::text)
    RETURNING * INTO new_image;

    RETURN new_image;
END;
$$;

-- RPC to delete an image from a service
CREATE OR REPLACE FUNCTION public.delete_service_image(p_image_id uuid)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    DELETE FROM public.service_images WHERE id = p_image_id;
END;
$$;

-- RPC to set an image as the primary one for a service
CREATE OR REPLACE FUNCTION public.set_primary_service_image(
    p_service_id uuid,
    p_image_id uuid
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    -- First, set all other images for this service to not be primary
    UPDATE public.service_images
    SET is_primary = false
    WHERE service_id = p_service_id AND is_primary = true;

    -- Then, set the specified image as primary
    UPDATE public.service_images
    SET is_primary = true
    WHERE id = p_image_id AND service_id = p_service_id;
END;
$$;

-- RPC to update the sort order of service images
CREATE OR REPLACE FUNCTION public.update_service_images_order(
    p_tenant_id uuid,
    p_images_data jsonb
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    CREATE TEMP TABLE new_order (
        id uuid,
        sort_order int
    ) ON COMMIT DROP;

    INSERT INTO new_order (id, sort_order)
    SELECT
        (value->>'id')::uuid,
        (value->>'sort_order')::int
    FROM jsonb_array_elements(p_images_data);

    UPDATE public.service_images AS si
    SET sort_order = no.sort_order
    FROM new_order AS no
    WHERE si.id = no.id AND si.tenant_id = p_tenant_id;
END;
$$;

-- Update search_services_function to include service_images
CREATE OR REPLACE FUNCTION public.search_services(
    p_tenant_id uuid,
    p_search_term text,
    p_category_id uuid,
    p_show_inactive boolean
)
RETURNS TABLE(
    id uuid,
    name text,
    description text,
    duration_minutes integer,
    price numeric,
    is_active boolean,
    is_visible_on_microsite boolean,
    requires_professional_assignment boolean,
    is_private boolean,
    sku text,
    name_i18n jsonb,
    description_i18n jsonb,
    category_name text,
    category_id uuid,
    service_images jsonb
)
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN QUERY
  SELECT
      s.id,
      s.name,
      s.description,
      s.duration_minutes,
      s.price,
      s.is_active,
      s.is_visible_on_microsite,
      s.requires_professional_assignment,
      s.is_private,
      s.sku,
      s.name_i18n,
      s.description_i18n,
      sc.name as category_name,
      s.category_id,
      COALESCE(si.images, '[]'::jsonb) AS service_images
  FROM services s
  LEFT JOIN service_categories sc ON s.category_id = sc.id
  LEFT JOIN (
      SELECT
          service_id,
          jsonb_agg(jsonb_build_object(
              'id', id,
              'image_url', image_url,
              'sort_order', sort_order,
              'is_primary', is_primary
          ) ORDER BY is_primary DESC, sort_order ASC) AS images
      FROM
          public.service_images
      GROUP BY
          service_id
  ) si ON s.id = si.service_id
  WHERE
      s.tenant_id = p_tenant_id
      AND (p_show_inactive OR s.is_active = TRUE)
      AND (p_category_id IS NULL OR s.category_id = p_category_id)
      AND (
          p_search_term IS NULL OR p_search_term = '' OR
          s.name ILIKE '%' || p_search_term || '%' OR
          s.description ILIKE '%' || p_search_term || '%' OR
          s.sku ILIKE '%' || p_search_term || '%'
      )
  ORDER BY s.name;
END;
$$;