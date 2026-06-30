-- Drop old and ambiguous function signatures
DROP FUNCTION IF EXISTS public.get_today_attentions(uuid);
DROP FUNCTION IF EXISTS public.get_today_attentions(uuid, uuid, uuid);

-- Create the new, consolidated function with timezone support
CREATE OR REPLACE FUNCTION public.get_today_attentions(
    p_tenant_id uuid,
    p_branch_id uuid,
    p_user_id uuid,
    p_timezone text
)
RETURNS TABLE (
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
DECLARE
    v_today date := (NOW() AT TIME ZONE p_timezone)::date;
BEGIN
    RETURN QUERY
    SELECT
        a.id, -- Returning attention ID
        to_char(a.attention_datetime AT TIME ZONE p_timezone, 'HH24:MI') as attention_time,
        c.name as client_name,
        s.name as service_name,
        u.first_name || ' ' || u.last_name as stylist_name,
        a.status,
        aserv.service_price as total_price -- This is what the original function returned
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
        AND (a.attention_datetime AT TIME ZONE p_timezone)::date = v_today
        AND (p_branch_id IS NULL OR a.branch_id = p_branch_id)
        AND (p_user_id IS NULL OR aserv.user_id = p_user_id)
    ORDER BY
        a.attention_datetime;
END;
$$;