-- This migration fixes the get_treatment_details RPC function again.
-- It corrects the source of the 'cover_image_url' column, using a subquery
-- to fetch the primary image from the 'treatment_images' table.

DROP FUNCTION IF EXISTS public.get_treatment_details(uuid);

CREATE OR REPLACE FUNCTION public.get_treatment_details(p_treatment_id uuid)
 RETURNS TABLE(
    id uuid,
    tenant_id uuid,
    name text,
    description text,
    type text,
    upfront_price numeric,
    financed_price numeric,
    is_active boolean,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    cover_image_url text,
    sessions jsonb
)
 LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT
        t.id,
        t.tenant_id,
        t.name,
        t.description,
        t.type,
        t.upfront_price,
        t.financed_price,
        t.is_active,
        t.created_at,
        t.updated_at,
        (SELECT ti.image_url FROM public.treatment_images ti WHERE ti.treatment_id = t.id AND ti.is_primary = TRUE LIMIT 1) AS cover_image_url,
        COALESCE(
            (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'id', ts.id,
                        'session_number', ts.session_number,
                        'name', ts.name,
                        'description', ts.description,
                        'payment_percentage', ts.payment_percentage,
                        'fixed_payment_amount', ts.fixed_payment_amount,
                        'items', COALESCE(
                            (
                                SELECT jsonb_agg(
                                    jsonb_build_object(
                                        'id', tsi.id,
                                        'product_id', tsi.product_id,
                                        'service_id', tsi.service_id,
                                        'quantity', tsi.quantity,
                                        'notes', tsi.notes,
                                        'product_name', p.name,
                                        'service_name', s.name
                                    )
                                )
                                FROM public.treatment_session_items tsi
                                LEFT JOIN public.products p ON tsi.product_id = p.id
                                LEFT JOIN public.services s ON tsi.service_id = s.id
                                WHERE tsi.session_id = ts.id
                            ),
                            '[]'::jsonb
                        )
                    )
                    ORDER BY ts.session_number
                )
                FROM public.treatment_sessions ts
                WHERE ts.treatment_id = t.id
            ),
            '[]'::jsonb
        ) AS sessions
    FROM
        public.treatments t
    WHERE
        t.id = p_treatment_id;
END;
$$;
