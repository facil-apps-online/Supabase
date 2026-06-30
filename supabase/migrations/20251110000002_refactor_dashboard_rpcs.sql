-- 20251110000002_refactor_dashboard_rpcs.sql

-- Function: get_today_attentions
-- Refactored to accept optional p_branch_id and p_user_id for role-based filtering.
-- Also adjusted to return attention_service.id for unique keys and formatted attention_time.
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
        (SELECT u.first_name || ' ' || u.last_name FROM users u WHERE u.id = aserv.user_id) as stylist_name,
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
    WHERE
        a.tenant_id = p_tenant_id
        AND a.attention_datetime::date = CURRENT_DATE
        AND (p_branch_id IS NULL OR a.branch_id = p_branch_id)
        AND (p_user_id IS NULL OR aserv.user_id = p_user_id)
    ORDER BY
        a.attention_datetime;
END;
$$;

-- Function: get_top_services
-- Refactored to accept optional p_branch_id and p_user_id for role-based filtering.
CREATE OR REPLACE FUNCTION public.get_top_services(
    p_tenant_id uuid,
    p_days integer DEFAULT 30,
    p_branch_id uuid DEFAULT NULL,
    p_user_id uuid DEFAULT NULL
)
RETURNS TABLE(
    name text,
    count bigint,
    revenue numeric
)
LANGUAGE plpgsql
AS $$
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
        AND a.attention_datetime >= (CURRENT_DATE - (p_days || ' days')::interval)
        AND (p_branch_id IS NULL OR a.branch_id = p_branch_id)
        AND (p_user_id IS NULL OR aserv.user_id = p_user_id)
    GROUP BY
        s.name
    ORDER BY
        count DESC
    LIMIT 5;
END;
$$;

-- Function: get_pending_commissions
-- Included for completeness, already accepts optional p_branch_id and p_user_id.
CREATE OR REPLACE FUNCTION get_pending_commissions(
  p_tenant_id uuid,
  p_branch_id uuid DEFAULT NULL,
  p_user_id uuid DEFAULT NULL
)
RETURNS TABLE(total_pending_commissions numeric) AS $$
BEGIN
  RETURN QUERY
  SELECT
    COALESCE(SUM(commission_amount), 0)
  FROM
    public.earned_commissions
  WHERE
    tenant_id = p_tenant_id
    AND status = 'earned'
    AND (p_branch_id IS NULL OR branch_id = p_branch_id)
    AND (p_user_id IS NULL OR user_id = p_user_id);
END;
$$ LANGUAGE plpgsql;