
CREATE OR REPLACE FUNCTION get_combo_branch_details(p_tenant_id uuid, p_branch_id uuid, p_combo_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    combo_details JSONB;
BEGIN
    -- NOTE: Security is handled by RLS policies and the calling edge function which verifies tenant access.

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
                    'override_price', bcip.price, -- The specific price for this branch, if it exists
                    'final_price', COALESCE(bcip.price, ci.price), -- Use override, fallback to base
                    'duration_minutes', s.duration_minutes,
                    'offset_minutes', ci.offset_minutes -- Añadido para el agendamiento
                )
            ), '[]'::jsonb)
            FROM combo_items ci
            LEFT JOIN products p ON p.id = ci.product_id
            LEFT JOIN services s ON s.id = ci.service_id
            LEFT JOIN branch_combo_item_prices bcip ON bcip.combo_id = ci.combo_id
                AND bcip.branch_id = p_branch_id
                AND (bcip.product_id = ci.product_id OR bcip.service_id = ci.service_id)
            WHERE ci.combo_id = c.id
        )
    )
    INTO combo_details
    FROM combos c
    LEFT JOIN branch_combos bc ON bc.combo_id = c.id AND bc.branch_id = p_branch_id
    WHERE c.id = p_combo_id AND c.tenant_id = p_tenant_id;

    RETURN combo_details;
END;
$$;
