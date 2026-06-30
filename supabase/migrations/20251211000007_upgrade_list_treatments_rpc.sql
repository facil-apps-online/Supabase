-- This migration upgrades the list_treatments RPC function to support filtering by active status.
-- 1. Drops the old version of the function.
-- 2. Creates a new version that accepts a p_show_inactive boolean parameter
--    and applies the is_active filter accordingly.

DROP FUNCTION IF EXISTS public.list_treatments(uuid, text);

CREATE OR REPLACE FUNCTION public.list_treatments(p_tenant_id uuid, p_type text, p_show_inactive boolean DEFAULT FALSE)
 RETURNS TABLE(id uuid, name text, description text, type text, upfront_price numeric, financed_price numeric, session_count bigint, cover_image_url text)
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN QUERY
    SELECT
        t.id,
        t.name,
        t.description,
        t.type,
        t.upfront_price,
        t.financed_price,
        COUNT(ts.id) AS session_count,
        (SELECT ti.image_url FROM public.treatment_images ti WHERE ti.treatment_id = t.id AND ti.is_primary = TRUE LIMIT 1) AS cover_image_url
    FROM
        public.treatments t
    LEFT JOIN
        public.treatment_sessions ts ON t.id = ts.treatment_id
    WHERE
        t.tenant_id = p_tenant_id
        AND t.type = p_type
        AND (p_show_inactive OR t.is_active = TRUE) -- Apply filter conditionally
    GROUP BY
        t.id
    ORDER BY
        t.name;
END;
$function$;
