-- Migration: 20260712000005_fix_get_product_sellers_platform_id.sql
-- Description: Updates get_product_sellers to accept and filter by p_platform_id.

DROP FUNCTION IF EXISTS public.get_product_sellers(uuid, uuid, uuid, text);
DROP FUNCTION IF EXISTS public.get_product_sellers(uuid, uuid, uuid, uuid, text);

CREATE OR REPLACE FUNCTION public.get_product_sellers(
    p_product_id uuid,
    p_branch_id uuid,
    p_tenant_id uuid,
    p_platform_id uuid,
    p_search_term text DEFAULT NULL
) 
RETURNS TABLE("user_id" uuid, "first_name" text, "last_name" text, "commission_rate" numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY
    SELECT
        u.id,
        (u.raw_user_meta_data ->> 'first_name'),
        (u.raw_user_meta_data ->> 'last_name'),
        COALESCE(
            (SELECT puc.commission_rate
             FROM public.product_user_commissions puc
             WHERE puc.user_id = ua.user_id
               AND puc.branch_id = ua.branch_id
               AND puc.product_id = p_product_id
             ORDER BY puc.created_at DESC
             LIMIT 1),
            ua.default_product_commission_rate,
            0.00
        ) AS commission_rate
    FROM
        public.user_assignments ua
    JOIN
        auth.users u ON ua.user_id = u.id
    WHERE
        ua.tenant_id = p_tenant_id
        AND ua.platform_id = p_platform_id
        AND ua.branch_id = p_branch_id
        AND ua.status = 'active'
        AND (
            p_search_term IS NULL OR
            (u.raw_user_meta_data ->> 'first_name') ILIKE '%' || p_search_term || '%' OR
            (u.raw_user_meta_data ->> 'last_name') ILIKE '%' || p_search_term || '%'
        );
END;
$$;
