DROP FUNCTION IF EXISTS public.get_today_attentions(uuid, uuid, uuid, text);

CREATE OR REPLACE FUNCTION public.get_today_attentions(p_tenant_id uuid, p_branch_id uuid, p_user_id uuid, p_timezone text)
 RETURNS TABLE(id uuid, attention_time text, client_name text, services jsonb, stylists jsonb, status text, total_price numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_today date := (NOW() AT TIME ZONE p_timezone)::date;
BEGIN
    RETURN QUERY
    WITH base_attentions AS (
        SELECT a.*
        FROM public.attentions a
        WHERE
            a.tenant_id = p_tenant_id
            AND (a.attention_datetime AT TIME ZONE p_timezone)::date = v_today
            AND a.status IN ('Pendiente', 'Confirmada')
            -- Simplified WHERE clause based on parameters from frontend
            AND (p_branch_id IS NULL OR a.branch_id = p_branch_id)
            AND (p_user_id IS NULL OR EXISTS (
                SELECT 1 FROM public.attention_services s_asgn
                WHERE s_asgn.attention_id = a.id AND s_asgn.user_id = p_user_id
            ))
    ),
    aggregated_data AS (
        SELECT
            aserv.attention_id,
            jsonb_agg(DISTINCT jsonb_build_object('id', s.id, 'name', s.name)) as services,
            jsonb_agg(DISTINCT jsonb_build_object('id', u.user_id, 'name', u.first_name || ' ' || u.last_name)) as stylists
        FROM public.attention_services aserv
        JOIN base_attentions ba ON aserv.attention_id = ba.id
        JOIN public.services s ON aserv.service_id = s.id
        JOIN public.get_tenant_users(p_tenant_id) u ON aserv.user_id = u.user_id
        GROUP BY aserv.attention_id
    )
    SELECT
        ba.id,
        to_char(ba.attention_datetime AT TIME ZONE p_timezone, 'HH24:MI') as attention_time,
        c.name as client_name,
        agd.services,
        agd.stylists,
        ba.status,
        ba.total_amount as total_price
    FROM
        base_attentions ba
    JOIN
        public.clients c ON ba.client_id = c.id
    LEFT JOIN
        aggregated_data agd ON ba.id = agd.attention_id
    ORDER BY
        ba.attention_datetime;
END;
$function$
;