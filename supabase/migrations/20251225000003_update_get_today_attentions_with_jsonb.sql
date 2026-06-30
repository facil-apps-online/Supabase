DROP FUNCTION IF EXISTS public.get_today_attentions(uuid, uuid, uuid, text);

CREATE OR REPLACE FUNCTION public.get_today_attentions(p_tenant_id uuid, p_branch_id uuid, p_user_id uuid, p_timezone text)
 RETURNS TABLE(id uuid, attention_time text, client_name text, services jsonb, stylists jsonb, status text, total_price numeric) -- Changed columns
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_today date := (NOW() AT TIME ZONE p_timezone)::date;
    v_caller_id uuid := auth.uid();
    v_caller_role_name text;
    v_caller_branch_id uuid;
BEGIN
    -- Get the role and branch of the user making the call
    SELECT r.name, ua.branch_id
    INTO v_caller_role_name, v_caller_branch_id
    FROM public.user_assignments ua
    JOIN public.roles r ON ua.role_id = r.id
    WHERE ua.user_id = v_caller_id AND ua.tenant_id = p_tenant_id
    LIMIT 1;

    RETURN QUERY
    WITH base_attentions AS (
        SELECT a.*
        FROM public.attentions a
        WHERE
            a.tenant_id = p_tenant_id
            AND (a.attention_datetime AT TIME ZONE p_timezone)::date = v_today
            AND
            (
                -- Super Admin sees all or filtered by parameter
                (v_caller_role_name = 'tenant_super_admin' AND (p_branch_id IS NULL OR a.branch_id = p_branch_id))
                OR
                -- Admin/Vendor sees everything from their own branch
                (v_caller_role_name IN ('tenant_admin', 'tenant_vendor') AND a.branch_id = v_caller_branch_id)
                OR
                -- Staff/User sees only attentions they are assigned to
                (v_caller_role_name = 'tenant_user' AND EXISTS (
                    SELECT 1 FROM public.attention_services s_asgn WHERE s_asgn.attention_id = a.id AND s_asgn.user_id = v_caller_id
                ))
            )
    ),
    aggregated_data AS (
        SELECT
            aserv.attention_id,
            jsonb_agg(DISTINCT jsonb_build_object('id', s.id, 'name', s.name)) as services,
            jsonb_agg(DISTINCT jsonb_build_object('id', u.user_id, 'name', u.first_name || ' ' || u.last_name)) as stylists
        FROM public.attention_services aserv
        JOIN public.services s ON aserv.service_id = s.id
        JOIN public.get_tenant_users(p_tenant_id) u ON aserv.user_id = u.user_id
        WHERE aserv.attention_id IN (SELECT id FROM base_attentions)
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