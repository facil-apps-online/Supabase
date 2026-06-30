-- This migration upgrades the list_treatments RPC function again.
-- It adds the ability to filter treatments by a specific category_id.

DROP FUNCTION IF EXISTS public.list_treatments(uuid, text, boolean);

CREATE OR REPLACE FUNCTION public.list_treatments(
    p_tenant_id uuid, 
    p_type text, 
    p_show_inactive boolean DEFAULT FALSE,
    p_category_id uuid DEFAULT NULL -- Added category filter
)
 RETURNS TABLE(
    id uuid,
    name text,
    description text,
    type text,
    upfront_price numeric,
    financed_price numeric,
    is_active boolean,
    session_count bigint,
    cover_image_url text,
    categories jsonb,
    treatment_images jsonb
)
 LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT
        t.id,
        t.name,
        t.description,
        t.type,
        t.upfront_price,
        t.financed_price,
        t.is_active,
        COUNT(ts.id) AS session_count,
        (SELECT ti.image_url FROM public.treatment_images ti WHERE ti.treatment_id = t.id AND ti.is_primary = TRUE LIMIT 1) AS cover_image_url,
        COALESCE(
            (SELECT jsonb_agg(jsonb_build_object('id', tc.id, 'name', tc.name))
            FROM public.treatment_category_assignments tca_inner
            JOIN public.treatment_categories tc ON tca_inner.category_id = tc.id
            WHERE tca_inner.treatment_id = t.id),
            '[]'::jsonb
        ) AS categories,
        COALESCE(
            (SELECT jsonb_agg(jsonb_build_object('id', ti.id, 'image_url', ti.image_url, 'is_primary', ti.is_primary, 'sort_order', ti.sort_order) ORDER BY ti.sort_order)
            FROM public.treatment_images ti
            WHERE ti.treatment_id = t.id),
            '[]'::jsonb
        ) AS treatment_images
    FROM
        public.treatments t
    LEFT JOIN
        public.treatment_sessions ts ON t.id = ts.treatment_id
    -- Join with assignments to filter by category
    LEFT JOIN
        public.treatment_category_assignments tca ON t.id = tca.treatment_id
    WHERE
        t.tenant_id = p_tenant_id
        AND t.type = p_type
        AND (p_show_inactive OR t.is_active = TRUE)
        AND (p_category_id IS NULL OR tca.category_id = p_category_id) -- Apply category filter
    GROUP BY
        t.id
    ORDER BY
        t.name;
END;
$$;
