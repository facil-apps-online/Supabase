-- This migration re-upgrades the list_treatments RPC function.
-- It adds back the 'is_active', 'categories', and 'treatment_images' fields
-- that were lost in a previous refactoring, restoring full functionality.

DROP FUNCTION IF EXISTS public.list_treatments(uuid, text, boolean);

CREATE OR REPLACE FUNCTION public.list_treatments(p_tenant_id uuid, p_type text, p_show_inactive boolean DEFAULT FALSE)
 RETURNS TABLE(
    id uuid,
    name text,
    description text,
    type text,
    upfront_price numeric,
    financed_price numeric,
    is_active boolean, -- Added
    session_count bigint,
    cover_image_url text,
    categories jsonb, -- Added
    treatment_images jsonb -- Added
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
        t.is_active, -- Added
        COUNT(ts.id) AS session_count,
        (SELECT ti.image_url FROM public.treatment_images ti WHERE ti.treatment_id = t.id AND ti.is_primary = TRUE LIMIT 1) AS cover_image_url,
        -- Aggregate categories
        COALESCE(
            (SELECT jsonb_agg(
                jsonb_build_object('id', tc.id, 'name', tc.name)
            )
            FROM public.treatment_category_assignments tca
            JOIN public.treatment_categories tc ON tca.category_id = tc.id
            WHERE tca.treatment_id = t.id),
            '[]'::jsonb
        ) AS categories,
        -- Aggregate all images
        COALESCE(
            (SELECT jsonb_agg(
                jsonb_build_object(
                    'id', ti.id,
                    'image_url', ti.image_url,
                    'is_primary', ti.is_primary,
                    'sort_order', ti.sort_order
                ) ORDER BY ti.sort_order
            )
            FROM public.treatment_images ti
            WHERE ti.treatment_id = t.id),
            '[]'::jsonb
        ) AS treatment_images
    FROM
        public.treatments t
    LEFT JOIN
        public.treatment_sessions ts ON t.id = ts.treatment_id
    WHERE
        t.tenant_id = p_tenant_id
        AND t.type = p_type
        AND (p_show_inactive OR t.is_active = TRUE)
    GROUP BY
        t.id
    ORDER BY
        t.name;
END;
$$;
