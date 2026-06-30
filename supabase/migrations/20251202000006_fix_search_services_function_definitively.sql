-- Drop all potentially conflicting search_services functions
DROP FUNCTION IF EXISTS public.search_services(uuid, text, boolean, uuid);
DROP FUNCTION IF EXISTS public.search_services(uuid, text, uuid, boolean);

-- Re-create the function with the correct schema and the new images logic
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
    is_active boolean,
    is_visible_on_microsite boolean,
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
      s.is_active,
      s.is_visible_on_microsite,
      s.is_private,
      s.sku,
      s.name_i18n,
      s.description_i18n,
      sc.name as category_name,
      s.category_id,
      COALESCE(si_agg.images, '[]'::jsonb) AS service_images
  FROM public.services s
  LEFT JOIN public.service_categories sc ON s.category_id = sc.id
  LEFT JOIN (
      SELECT
          si_img.service_id,
          jsonb_agg(jsonb_build_object(
              'id', si_img.id,
              'image_url', si_img.image_url,
              'sort_order', si_img.sort_order,
              'is_primary', si_img.is_primary
          ) ORDER BY si_img.is_primary DESC, si_img.sort_order ASC) AS images
      FROM
          public.service_images si_img
      GROUP BY
          si_img.service_id
  ) si_agg ON s.id = si_agg.service_id
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