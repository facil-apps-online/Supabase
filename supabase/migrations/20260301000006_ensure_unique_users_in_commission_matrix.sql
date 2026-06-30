-- Migration: ensure_unique_users_in_commission_matrix
-- Created at: 2026-03-01 00:00:06

--------------------------------------------------------------------------------
-- 1. get_product_commission_matrix
--------------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.get_product_commission_matrix(uuid, uuid, uuid);
CREATE OR REPLACE FUNCTION public.get_product_commission_matrix(p_tenant_id uuid, p_platform_id uuid, p_product_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    result jsonb;
BEGIN
    WITH user_data AS (
        -- Get unique users for the tenant
        SELECT DISTINCT ON (u.user_id)
            u.user_id, 
            u.first_name, 
            u.last_name,
            u.default_product_commission_rate
        FROM public.get_tenant_users(p_tenant_id, p_platform_id) u
    ),
    branch_assignments AS (
        -- Get unique branch assignments for these users
        SELECT DISTINCT ON (ua.user_id, ua.branch_id)
            ua.user_id,
            ua.branch_id,
            b.name as branch_name
        FROM public.user_assignments ua
        JOIN public.branches b ON ua.branch_id = b.id
        WHERE ua.tenant_id = p_tenant_id AND ua.platform_id = p_platform_id
    ),
    user_branches AS (
        -- Combine user with their branches and pick only ONE commission record (the most recent)
        SELECT 
            ud.user_id,
            ud.first_name,
            ud.last_name,
            jsonb_agg(
                jsonb_build_object(
                    'branch_id', ba.branch_id,
                    'branch_name', ba.branch_name,
                    'commission_rate', COALESCE(
                        (SELECT puc.commission_rate 
                         FROM public.product_user_commissions puc 
                         WHERE puc.user_id = ud.user_id 
                           AND puc.product_id = p_product_id 
                           AND puc.tenant_id = p_tenant_id 
                           AND puc.platform_id = p_platform_id 
                           AND puc.branch_id = ba.branch_id
                         ORDER BY puc.created_at DESC LIMIT 1), 
                        ud.default_product_commission_rate
                    ),
                    'commission_id', (SELECT puc.id 
                                     FROM public.product_user_commissions puc 
                                     WHERE puc.user_id = ud.user_id 
                                       AND puc.product_id = p_product_id 
                                       AND puc.tenant_id = p_tenant_id 
                                       AND puc.platform_id = p_platform_id 
                                       AND puc.branch_id = ba.branch_id
                                     ORDER BY puc.created_at DESC LIMIT 1)
                )
            ) as branches
        FROM user_data ud
        JOIN branch_assignments ba ON ud.user_id = ba.user_id
        GROUP BY ud.user_id, ud.first_name, ud.last_name
    )
    SELECT jsonb_agg(
        jsonb_build_object(
            'user_id', ub.user_id,
            'first_name', ub.first_name,
            'last_name', ub.last_name,
            'user_name', (ub.first_name || ' ' || ub.last_name),
            'branches', ub.branches
        )
    ) INTO result
    FROM user_branches ub;

    RETURN COALESCE(result, '[]'::jsonb);
END;
$function$;

--------------------------------------------------------------------------------
-- 2. get_service_commission_matrix
--------------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.get_service_commission_matrix(uuid, uuid, uuid);
CREATE OR REPLACE FUNCTION public.get_service_commission_matrix(p_tenant_id uuid, p_platform_id uuid, p_service_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    result jsonb;
BEGIN
    WITH user_data AS (
        -- Get unique users for the tenant
        SELECT DISTINCT ON (u.user_id)
            u.user_id, 
            u.first_name, 
            u.last_name,
            u.default_service_commission_rate
        FROM public.get_tenant_users(p_tenant_id, p_platform_id) u
    ),
    branch_assignments AS (
        -- Get unique branch assignments for these users
        SELECT DISTINCT ON (ua.user_id, ua.branch_id)
            ua.user_id,
            ua.branch_id,
            b.name as branch_name
        FROM public.user_assignments ua
        JOIN public.branches b ON ua.branch_id = b.id
        WHERE ua.tenant_id = p_tenant_id AND ua.platform_id = p_platform_id
    ),
    user_branches AS (
        -- Combine user with their branches and pick only ONE commission record (the most recent)
        SELECT 
            ud.user_id,
            ud.first_name,
            ud.last_name,
            jsonb_agg(
                jsonb_build_object(
                    'branch_id', ba.branch_id,
                    'branch_name', ba.branch_name,
                    'commission_rate', COALESCE(
                        (SELECT suc.commission_rate 
                         FROM public.service_user_commissions suc 
                         WHERE suc.user_id = ud.user_id 
                           AND suc.service_id = p_service_id 
                           AND suc.tenant_id = p_tenant_id 
                           AND suc.platform_id = p_platform_id 
                           AND suc.branch_id = ba.branch_id
                         ORDER BY suc.created_at DESC LIMIT 1), 
                        ud.default_service_commission_rate
                    ),
                    'commission_id', (SELECT suc.id 
                                     FROM public.service_user_commissions suc 
                                     WHERE suc.user_id = ud.user_id 
                                       AND suc.service_id = p_service_id 
                                       AND suc.tenant_id = p_tenant_id 
                                       AND suc.platform_id = p_platform_id 
                                       AND suc.branch_id = ba.branch_id
                                     ORDER BY suc.created_at DESC LIMIT 1)
                )
            ) as branches
        FROM user_data ud
        JOIN branch_assignments ba ON ud.user_id = ba.user_id
        GROUP BY ud.user_id, ud.first_name, ud.last_name
    )
    SELECT jsonb_agg(
        jsonb_build_object(
            'user_id', ub.user_id,
            'first_name', ub.first_name,
            'last_name', ub.last_name,
            'user_name', (ub.first_name || ' ' || ub.last_name),
            'branches', ub.branches
        )
    ) INTO result
    FROM user_branches ub;

    RETURN COALESCE(result, '[]'::jsonb);
END;
$function$;
