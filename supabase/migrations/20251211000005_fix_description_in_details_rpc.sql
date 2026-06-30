-- This migration fixes the get_client_treatment_details RPC function again.
-- It corrects the source of the 'description' column, pulling it from the
-- treatment prototype table 't' instead of the client treatment table 'ct'.

DROP FUNCTION IF EXISTS public.get_client_treatment_details(uuid);

CREATE OR REPLACE FUNCTION public.get_client_treatment_details(p_client_treatment_id uuid)
 RETURNS TABLE(
    id uuid, 
    client_id uuid, 
    prototype_id uuid,
    name text, 
    description text, -- This remains, but its source is corrected below
    status text, 
    start_date timestamptz, 
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
        t.description, -- CORRECTED: Source is the prototype table 't'
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
