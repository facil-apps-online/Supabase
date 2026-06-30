-- 20251110000003_fix_get_today_attentions_rpc.sql

-- Function: get_today_attentions
-- Corrected to use get_tenant_users function to fetch stylist name,
-- as direct auth.users queries are not permitted and name is stored as first_name/last_name.
CREATE OR REPLACE FUNCTION public.get_today_attentions(
    p_tenant_id uuid,
    p_branch_id uuid DEFAULT NULL,
    p_user_id uuid DEFAULT NULL
)
RETURNS TABLE(
    id uuid,
    attention_time text,
    client_name text,
    service_name text,
    stylist_name text,
    status text,
    total_price numeric
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT
        aserv.id,
        to_char(a.attention_datetime, 'HH24:MI') as attention_time,
        c.name as client_name,
        s.name as service_name,
        u.first_name || ' ' || u.last_name as stylist_name,
        a.status,
        aserv.service_price as total_price
    FROM
        public.attention_services aserv
    JOIN
        public.attentions a ON aserv.attention_id = a.id
    JOIN
        public.clients c ON a.client_id = c.id
    JOIN
        public.services s ON aserv.service_id = s.id
    JOIN
        public.get_tenant_users(p_tenant_id) u ON aserv.user_id = u.user_id
    WHERE
        a.tenant_id = p_tenant_id
        AND a.attention_datetime::date = CURRENT_DATE
        AND (p_branch_id IS NULL OR a.branch_id = p_branch_id)
        AND (p_user_id IS NULL OR aserv.user_id = p_user_id)
    ORDER BY
        a.attention_datetime;
END;
$$;