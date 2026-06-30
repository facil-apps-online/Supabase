CREATE OR REPLACE FUNCTION "public"."get_today_attentions"("p_tenant_id" "uuid") RETURNS TABLE("id" "uuid", "attention_datetime" timestamp with time zone, "client_name" "text", "service_name" "text", "user_name" "text", "status" "text", "total_price" numeric)
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        a.id,
        a.attention_datetime,
        c.name AS client_name,
        s.name AS service_name,
        u.first_name || ' ' || u.last_name AS user_name,
        a.status,
        a.total_amount
    FROM 
        public.attentions a
    JOIN 
        public.clients c ON a.client_id = c.id
    JOIN 
        public.attention_services aserv ON a.id = aserv.attention_id
    JOIN 
        public.services s ON aserv.service_id = s.id
    JOIN 
        (SELECT DISTINCT ON (user_id) * FROM public.get_tenant_users(p_tenant_id)) u ON aserv.user_id = u.user_id
    WHERE 
        a.tenant_id = p_tenant_id 
        AND a.attention_datetime::date = CURRENT_DATE
    ORDER BY 
        a.attention_datetime;
END;
$$;