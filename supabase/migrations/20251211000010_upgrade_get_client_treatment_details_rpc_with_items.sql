-- This migration upgrades the get_client_treatment_details RPC function
-- to include the nested 'items' array within each session object,
-- fetching data from the new 'client_treatment_session_items' table.

DROP FUNCTION IF EXISTS public.get_client_treatment_details(uuid);

CREATE OR REPLACE FUNCTION public.get_client_treatment_details(p_client_treatment_id uuid)
 RETURNS TABLE(
    id uuid, 
    client_id uuid, 
    prototype_id uuid,
    name text, 
    description text,
    status text, 
    start_date date,
    final_price numeric, 
    payment_type text, 
    cover_image_url text, 
    sessions jsonb
)
 LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT
        ct.id,
        ct.client_id,
        ct.prototype_id,
        ct.name,
        t.description,
        ct.status,
        ct.start_date,
        ct.final_price,
        ct.payment_type,
        (SELECT ti.image_url FROM public.treatment_images ti WHERE ti.treatment_id = t.id AND ti.is_primary = TRUE LIMIT 1) AS cover_image_url,
        COALESCE(
            (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'id', cts.id,
                        'session_number', cts.session_number,
                        'name', cts.name,
                        'description', cts.description,
                        'status', cts.status,
                        'completed_at', cts.completed_at,
                        'attention_id', cts.attention_id,
                        'payment_due', jsonb_build_object(
                            'amount', cts.payment_due_amount,
                            'status', cts.payment_status
                        ),
                        'items', COALESCE(
                            (
                                SELECT jsonb_agg(
                                    jsonb_build_object(
                                        'id', ctsi.id,
                                        'product_id', ctsi.product_id,
                                        'service_id', ctsi.service_id,
                                        'quantity', ctsi.quantity,
                                        'notes', ctsi.notes,
                                        'product_name', p.name, -- Include product name
                                        'service_name', s.name  -- Include service name
                                    )
                                )
                                FROM public.client_treatment_session_items ctsi
                                LEFT JOIN public.products p ON ctsi.product_id = p.id
                                LEFT JOIN public.services s ON ctsi.service_id = s.id
                                WHERE ctsi.client_treatment_session_id = cts.id
                            ),
                            '[]'::jsonb
                        )
                    )
                    ORDER BY cts.session_number
                )
                FROM public.client_treatment_sessions cts
                WHERE cts.client_treatment_id = ct.id
            ),
            '[]'::jsonb
        ) AS sessions
    FROM
        public.client_treatments ct
    LEFT JOIN
        public.treatments t ON ct.prototype_id = t.id
    WHERE
        ct.id = p_client_treatment_id;
END;
$$;
