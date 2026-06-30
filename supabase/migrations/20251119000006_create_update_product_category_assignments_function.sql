CREATE OR REPLACE FUNCTION public.update_product_category_assignments(
    p_tenant_id uuid,
    p_product_id uuid,
    p_category_ids uuid[]
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    -- First, delete all existing assignments for this product
    DELETE FROM public.product_category_assignments
    WHERE product_id = p_product_id AND tenant_id = p_tenant_id;

    -- Then, insert the new assignments if any are provided
    IF array_length(p_category_ids, 1) > 0 THEN
        INSERT INTO public.product_category_assignments (product_id, category_id, tenant_id)
        SELECT p_product_id, category_id, p_tenant_id
        FROM unnest(p_category_ids) AS t(category_id);
    END IF;
END;
$$;
