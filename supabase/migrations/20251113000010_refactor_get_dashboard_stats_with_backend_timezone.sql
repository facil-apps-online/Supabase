-- Drop the function with the client-side timezone parameter
DROP FUNCTION IF EXISTS public.get_dashboard_stats(uuid, uuid, uuid, text);

-- Create the new function that determines timezone on the backend
CREATE OR REPLACE FUNCTION public.get_dashboard_stats(
    p_tenant_id uuid,
    p_branch_id uuid,
    p_user_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    v_stats jsonb;
    v_timezone text;
    v_today date;
    v_yesterday date;
    v_start_of_this_month timestamptz;
    v_start_of_last_month timestamptz;
BEGIN
    -- 1. Determine the correct timezone based on context
    IF p_branch_id IS NOT NULL THEN
        SELECT timezone INTO v_timezone FROM public.branches WHERE id = p_branch_id;
    END IF;

    -- Fallback to tenant timezone if branch timezone is null or branch is not provided
    IF v_timezone IS NULL THEN
        SELECT default_timezone INTO v_timezone FROM public.tenants WHERE id = p_tenant_id;
    END IF;

    -- Final fallback to UTC if no timezone is found anywhere
    v_timezone := COALESCE(v_timezone, 'UTC');

    -- 2. Calculate date boundaries using the determined timezone
    v_today := (NOW() AT TIME ZONE v_timezone)::date;
    v_yesterday := v_today - INTERVAL '1 day';
    v_start_of_this_month := date_trunc('month', NOW() AT TIME ZONE v_timezone);
    v_start_of_last_month := v_start_of_this_month - INTERVAL '1 month';

    -- 3. Main query logic
    WITH base_attentions AS (
        SELECT
            a.id,
            a.total_amount,
            a.attention_datetime,
            (a.attention_datetime AT TIME ZONE v_timezone)::date as local_attention_date,
            a.status
        FROM public.attentions a
        WHERE a.tenant_id = p_tenant_id
          AND (p_branch_id IS NULL OR a.branch_id = p_branch_id)
          AND (
              p_user_id IS NULL
              OR EXISTS (
                  SELECT 1 FROM public.attention_services s
                  WHERE s.attention_id = a.id AND s.user_id = p_user_id
              )
              OR EXISTS (
                  SELECT 1 FROM public.attention_products p
                  WHERE p.attention_id = a.id AND p.user_id = p_user_id
              )
          )
    ),
    paid_attentions AS (
        SELECT * FROM base_attentions
        WHERE status IN ('Finalizada', 'Pagada')
    )
    SELECT jsonb_build_object(
        'todayRevenue', (SELECT COALESCE(SUM(total_amount), 0) FROM paid_attentions WHERE local_attention_date = v_today),
        'monthlyRevenue', (SELECT COALESCE(SUM(total_amount), 0) FROM paid_attentions WHERE attention_datetime >= v_start_of_this_month AND attention_datetime < v_start_of_this_month + INTERVAL '1 month'),
        'todayAppointments', (SELECT COALESCE(COUNT(*), 0) FROM base_attentions WHERE local_attention_date = v_today),
        'activeStylists', (SELECT COUNT(DISTINCT user_id) FROM public.get_tenant_users(p_tenant_id) WHERE status = 'active' AND (p_branch_id IS NULL OR branch_id = p_branch_id)),
        'revenueChange', (
            SELECT COALESCE(((today.revenue - yesterday.revenue) / NULLIF(yesterday.revenue, 0) * 100), 0)
            FROM
                (SELECT COALESCE(SUM(total_amount), 0) as revenue FROM paid_attentions WHERE local_attention_date = v_today) today,
                (SELECT COALESCE(SUM(total_amount), 0) as revenue FROM paid_attentions WHERE local_attention_date = v_yesterday) yesterday
        ),
        'appointmentsChange', (
            SELECT COALESCE(((today.count - yesterday.count) / NULLIF(yesterday.count, 0) * 100), 0)
            FROM
                (SELECT COALESCE(COUNT(*), 0) as count FROM base_attentions WHERE local_attention_date = v_today) today,
                (SELECT COALESCE(COUNT(*), 0) as count FROM base_attentions WHERE local_attention_date = v_yesterday) yesterday
        ),
        'monthlyRevenueChange', (
            SELECT COALESCE(((this_month.revenue - last_month.revenue) / NULLIF(last_month.revenue, 0) * 100), 0)
            FROM
                (SELECT COALESCE(SUM(total_amount), 0) as revenue FROM paid_attentions WHERE attention_datetime >= v_start_of_this_month AND attention_datetime < v_start_of_this_month + INTERVAL '1 month') this_month,
                (SELECT COALESCE(SUM(total_amount), 0) as revenue FROM paid_attentions WHERE attention_datetime >= v_start_of_last_month AND attention_datetime < v_start_of_this_month) last_month
        )
    ) INTO v_stats;

    RETURN v_stats;
END;
$$;