-- This migration upgrades the get_treatment_details RPC function
-- to return a richer object that includes its associated sessions and their items.
-- This is necessary for the AssignTreatmentDialog to display and manage session items.

DROP FUNCTION IF EXISTS public.get_treatment_details(uuid);

CREATE OR REPLACE FUNCTION public.get_treatment_details(p_treatment_id uuid)
 RETURNS TABLE(
    id uuid,
    tenant_id uuid,
    name text,
    description text,
    type text,
    upfront_price numeric,
    financed_price numeric,
    is_active boolean,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    cover_image_url text,
    sessions jsonb
)
 LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT
        t.id,
        t.tenant_id,
        t.name,
        t.description,
        t.type,
        t.upfront_price,
        t.financed_price,
        t.is_active,
        t.created_at,
        t.updated_at,
        t.cover_image_url,
        COALESCE(
            (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'id', ts.id,
                        'session_number', ts.session_number,
                        'name', ts.name,
                        'description', ts.description,
                        'payment_percentage', ts.payment_percentage,
                        'fixed_payment_amount', ts.fixed_payment_amount,
                        'items', COALESCE(
                            (
                                SELECT jsonb_agg(
                                    jsonb_build_object(
                                        'id', tsi.id,
                                        'product_id', tsi.product_id,
                                        'service_id', tsi.service_id,
                                        'quantity', tsi.quantity,
                                        'notes', tsi.notes,
                                        'product_name', p.name, -- Include product name
                                        'service_name', s.name  -- Include service name
                                    )
                                )
                                FROM public.treatment_session_items tsi
                                LEFT JOIN public.products p ON tsi.product_id = p.id
                                LEFT JOIN public.services s ON tsi.service_id = s.id
                                WHERE tsi.session_id = ts.id
                            ),
                            '[]'::jsonb
                        )
                    )
                    ORDER BY ts.session_number
                )
                FROM public.treatment_sessions ts
                WHERE ts.treatment_id = t.id
            ),
            '[]'::jsonb
        ) AS sessions
    FROM
        public.treatments t
    WHERE
        t.id = p_treatment_id;
END;
$$;
