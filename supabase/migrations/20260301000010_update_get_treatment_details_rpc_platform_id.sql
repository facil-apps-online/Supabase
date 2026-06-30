-- Migration: update_get_treatment_details_rpc_platform_id
-- Created at: 2026-03-01 00:00:10

DROP FUNCTION IF EXISTS public.get_treatment_details(uuid);
CREATE OR REPLACE FUNCTION public.get_treatment_details(p_tenant_id uuid, p_platform_id uuid, p_treatment_id uuid)
 RETURNS TABLE(id uuid, tenant_id uuid, platform_id uuid, name text, description text, type text, upfront_price numeric, financed_price numeric, is_active boolean, created_at timestamp with time zone, updated_at timestamp with time zone, cover_image_url text, sessions jsonb, categories jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
    RETURN QUERY
    SELECT
        t.id,
        t.tenant_id,
        t.platform_id,
        t.name,
        t.description,
        t.type,
        t.upfront_price,
        t.financed_price,
        t.is_active,
        t.created_at,
        t.updated_at,
        (SELECT ti.image_url FROM public.treatment_images ti WHERE ti.treatment_id = t.id AND ti.is_primary = TRUE AND ti.platform_id = p_platform_id LIMIT 1) AS cover_image_url,
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
                                LEFT JOIN public.products p ON tsi.product_id = p.id AND p.platform_id = p_platform_id
                                LEFT JOIN public.services s ON tsi.service_id = s.id AND s.platform_id = p_platform_id
                                WHERE tsi.session_id = ts.id
                                  AND tsi.platform_id = p_platform_id
                            ),
                            '[]'::jsonb
                        )
                    )
                    ORDER BY ts.session_number
                )
                FROM public.treatment_sessions ts
                WHERE ts.treatment_id = t.id
                  AND ts.platform_id = p_platform_id
            ),
            '[]'::jsonb
        ) AS sessions,
        COALESCE(
            (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'id', tc.id,
                        'name', tc.name
                    )
                )
                FROM public.treatment_category_assignments tca
                JOIN public.treatment_categories tc ON tca.category_id = tc.id
                WHERE tca.treatment_id = t.id
                  AND tca.platform_id = p_platform_id
            ),
            '[]'::jsonb
        ) AS categories
    FROM
        public.treatments t
    WHERE
        t.id = p_treatment_id
        AND t.tenant_id = p_tenant_id
        AND t.platform_id = p_platform_id;
END;
$function$;
