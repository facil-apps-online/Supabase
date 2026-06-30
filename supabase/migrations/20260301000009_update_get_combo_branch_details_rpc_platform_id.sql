-- Migration: update_get_combo_branch_details_rpc_platform_id
-- Created at: 2026-03-01 00:00:09

DROP FUNCTION IF EXISTS public.get_combo_branch_details(uuid, uuid, uuid);
CREATE OR REPLACE FUNCTION public.get_combo_branch_details(p_tenant_id uuid, p_platform_id uuid, p_branch_id uuid, p_combo_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    combo_details JSONB;
BEGIN
    SELECT jsonb_build_object(
        'id', c.id,
        'name', c.name,
        'description', c.description,
        'sku', c.sku,
        'is_active_in_branch', bc.is_active,
        'is_visible_on_microsite', COALESCE(bc.is_visible_on_microsite, false),
        'items', (
            SELECT COALESCE(jsonb_agg(
                jsonb_build_object(
                    'item_id', ci.id,
                    'product_id', ci.product_id,
                    'service_id', ci.service_id,
                    'name', COALESCE(p.name, s.name),
                    'quantity', ci.quantity,
                    'base_price', ci.price,
                    'override_price', bcip.price,
                    'final_price', COALESCE(bcip.price, ci.price),
                    'duration_minutes', s.duration_minutes,
                    'offset_minutes', ci.offset_minutes
                )
            ), '[]'::jsonb)
            FROM public.combo_items ci
            LEFT JOIN public.products p ON p.id = ci.product_id AND p.platform_id = p_platform_id
            LEFT JOIN public.services s ON s.id = ci.service_id AND s.platform_id = p_platform_id
            LEFT JOIN public.branch_combo_item_prices bcip ON bcip.combo_id = ci.combo_id
                AND bcip.branch_id = p_branch_id
                AND bcip.platform_id = p_platform_id
                AND (bcip.product_id = ci.product_id OR bcip.service_id = ci.service_id)
            WHERE ci.combo_id = c.id
              AND ci.platform_id = p_platform_id
        )
    )
    INTO combo_details
    FROM public.combos c
    LEFT JOIN public.branch_combos bc ON bc.combo_id = c.id AND bc.branch_id = p_branch_id AND bc.platform_id = p_platform_id
    WHERE c.id = p_combo_id 
      AND c.tenant_id = p_tenant_id
      AND c.platform_id = p_platform_id;

    RETURN combo_details;
END;
$function$;
