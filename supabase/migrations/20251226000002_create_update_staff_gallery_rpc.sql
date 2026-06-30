CREATE OR REPLACE FUNCTION update_staff_gallery_settings(
    p_tenant_id UUID,
    p_user_id UUID,
    p_gallery_items JSONB
)
RETURNS void AS $$
DECLARE
    item RECORD;
BEGIN
    -- First, set all existing items for this user as not favorite
    UPDATE public.staff_gallery_items
    SET is_favorite = false
    WHERE tenant_id = p_tenant_id AND user_id = p_user_id;

    -- Now, loop through the provided items and upsert them as favorites with the new order
    FOR item IN SELECT * FROM jsonb_to_recordset(p_gallery_items) AS x(evidence_id UUID, display_order INT)
    LOOP
        INSERT INTO public.staff_gallery_items (
            tenant_id,
            user_id,
            evidence_id,
            display_order,
            is_favorite
        )
        VALUES (
            p_tenant_id,
            p_user_id,
            item.evidence_id,
            item.display_order,
            true
        )
        ON CONFLICT (tenant_id, user_id, evidence_id)
        DO UPDATE SET
            display_order = EXCLUDED.display_order,
            is_favorite = EXCLUDED.is_favorite,
            updated_at = NOW();
    END LOOP;
END;
$$ LANGUAGE plpgsql;
