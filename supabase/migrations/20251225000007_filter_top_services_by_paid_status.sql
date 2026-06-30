DROP FUNCTION IF EXISTS public.get_top_services(uuid, uuid, uuid, integer, text);

CREATE OR REPLACE FUNCTION public.get_top_services(p_tenant_id uuid, p_branch_id uuid, p_user_id uuid, p_days integer, p_timezone text)
 RETURNS TABLE(name text, count bigint, revenue numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_start_date timestamptz := (NOW() AT TIME ZONE p_timezone) - (p_days || ' days')::interval;
BEGIN
    RETURN QUERY
    SELECT
        s.name,
        COUNT(aserv.id)::bigint as count,
        SUM(aserv.service_price) as revenue
    FROM
        public.attention_services aserv
    JOIN
        public.services s ON aserv.service_id = s.id
    JOIN
        public.attentions a ON aserv.attention_id = a.id
    WHERE
        a.tenant_id = p_tenant_id
        AND a.attention_datetime >= v_start_date
        AND a.status IN ('Pagada', 'Finalizada') -- Filter for paid/finalized attentions
        AND (p_branch_id IS NULL OR a.branch_id = p_branch_id)
        AND (p_user_id IS NULL OR aserv.user_id = p_user_id)
    GROUP BY
        s.name
    ORDER BY
        count DESC
    LIMIT 5;
END;
$function$
;