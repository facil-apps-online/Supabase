CREATE OR REPLACE FUNCTION public.search_products(
    p_tenant_id uuid,
    p_search_term text,
    p_show_inactive boolean,
    p_category_id uuid,
    p_brand_id uuid
)
RETURNS TABLE(
    id uuid,
    name text,
    description text,
    is_active boolean,
    created_at timestamptz,
    updated_at timestamptz,
    cost_price numeric,
    last_purchase_cost numeric,
    average_cost numeric,
    brand_id uuid,
    barcode text,
    sku text,
    tenant_id uuid,
    name_i18n jsonb,
    description_i18n jsonb,
    unit_of_measure_id uuid,
    package_content_quantity numeric,
    allow_decimal_sale boolean,
    product_images jsonb,
    product_categories jsonb
)
LANGUAGE plpgsql
AS $$
DECLARE
    search_words TEXT[];
    word TEXT;
    query_conditions TEXT[] := ARRAY[]::TEXT[];
    final_query TEXT;
BEGIN
    -- Split the search term into words
    IF p_search_term IS NOT NULL AND p_search_term <> '' THEN
        search_words := string_to_array(lower(p_search_term), ' ');
    ELSE
        search_words := ARRAY[]::TEXT[];
    END IF;

    -- Build the query conditions for each word
    FOREACH word IN ARRAY search_words
    LOOP
        IF word <> '' THEN
            query_conditions := array_append(
                query_conditions,
                format(
                    '(p.name ILIKE %1$L OR p.description ILIKE %1$L OR p.sku ILIKE %1$L OR p.barcode ILIKE %1$L)',
                    '%' || word || '%'
                )
            );
        END IF;
    END LOOP;

    -- Construct the final query
    final_query := '
        SELECT
            p.id,
            p.name,
            p.description,
            p.is_active,
            p.created_at,
            p.updated_at,
            p.cost_price,
            p.last_purchase_cost,
            p.average_cost,
            p.brand_id,
            p.barcode,
            p.sku,
            p.tenant_id,
            p.name_i18n,
            p.description_i18n,
            p.unit_of_measure_id,
            p.package_content_quantity,
            p.allow_decimal_sale,
            COALESCE(pi.images, ''[]''::jsonb) AS product_images,
            COALESCE(pc.categories, ''[]''::jsonb) as product_categories
        FROM
            public.products p
        LEFT JOIN (
            SELECT
                product_id,
                jsonb_agg(jsonb_build_object(
                    ''id'', id,
                    ''image_url'', image_url,
                    ''sort_order'', sort_order,
                    ''is_primary'', is_primary
                ) ORDER BY is_primary DESC, sort_order ASC) AS images
            FROM
                public.product_images
            GROUP BY
                product_id
        ) pi ON p.id = pi.product_id
        LEFT JOIN (
            SELECT
                pca.product_id,
                jsonb_agg(jsonb_build_object(''id'', pc.id, ''name'', pc.name) ORDER BY pc.name) AS categories
            FROM
                public.product_category_assignments pca
            JOIN
                public.product_categories pc ON pca.category_id = pc.id
            GROUP BY
                pca.product_id
        ) pc ON p.id = pc.product_id
        WHERE
            p.tenant_id = $1';

    IF NOT p_show_inactive THEN
        final_query := final_query || '
            AND p.is_active = TRUE';
    END IF;

    -- Use the new p_category_id to filter
    IF p_category_id IS NOT NULL THEN
        final_query := final_query || format('
            AND p.id IN (SELECT product_id FROM public.product_category_assignments WHERE category_id = %L)', p_category_id);
    END IF;

    IF p_brand_id IS NOT NULL THEN
        final_query := final_query || format('
            AND p.brand_id = %L', p_brand_id);
    END IF;

    IF array_length(query_conditions, 1) > 0 THEN
        final_query := final_query || '
            AND (' || array_to_string(query_conditions, ' AND ') || ')';
    END IF;

    final_query := final_query || '
        ORDER BY p.name;';

    -- Execute the query
    RETURN QUERY EXECUTE final_query USING p_tenant_id;
END;
$$;
