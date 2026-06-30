DROP FUNCTION IF EXISTS public.get_client_treatment_details(p_client_treatment_id uuid);

CREATE OR REPLACE FUNCTION public.get_client_treatment_details(p_client_treatment_id uuid)
 RETURNS TABLE(details jsonb)
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN QUERY
    SELECT jsonb_build_object(
        'id', ct.id,
        'client_id', ct.client_id,
        'prototype_id', ct.prototype_id,
        'name', ct.name,
        'description', t.description,
        'status', ct.status,
        'start_date', ct.start_date,
        'final_price', ct.final_price,
        'payment_type', ct.payment_type,
        'cover_image_url', (SELECT ti.image_url FROM public.treatment_images ti WHERE ti.treatment_id = t.id AND ti.is_primary = TRUE LIMIT 1),
        'sessions', COALESCE(
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
                        'attention_datetime', a.attention_datetime, -- CAMPO AÑADIDO
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
                                        'product_name', p.name,
                                        'service_name', s.name
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
                LEFT JOIN public.attentions a ON cts.attention_id = a.id -- JOIN AÑADIDO
                WHERE cts.client_treatment_id = ct.id
            ),
            '[]'::jsonb
        )
    )
    FROM
        public.client_treatments ct
    LEFT JOIN
        public.treatments t ON ct.prototype_id = t.id
    WHERE
        ct.id = p_client_treatment_id;
END;
$function$;