CREATE OR REPLACE FUNCTION public.update_product_images_order(
    p_tenant_id uuid,
    p_images_data jsonb
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    -- Use a temporary table to hold the new order data
    CREATE TEMP TABLE new_order (
        id uuid,
        sort_order int
    ) ON COMMIT DROP;

    -- Insert the data from the JSONB array into the temp table
    INSERT INTO new_order (id, sort_order)
    SELECT
        (value->>'id')::uuid,
        (value->>'sort_order')::int
    FROM jsonb_array_elements(p_images_data);

    -- Update the product_images table by joining with the temp table
    UPDATE public.product_images AS pi
    SET sort_order = no.sort_order
    FROM new_order AS no
    WHERE pi.id = no.id AND pi.tenant_id = p_tenant_id;

END;
$$;
