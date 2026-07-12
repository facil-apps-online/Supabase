-- Fix Payment Stats RPCs to exclude owner tenants and check dates for active subs
-- Timestamp: 20260708000003

DROP FUNCTION IF EXISTS public.get_platform_financial_stats(uuid);
DROP FUNCTION IF EXISTS public.get_platforms_stats();

-- 1. get_platform_financial_stats
CREATE OR REPLACE FUNCTION public.get_platform_financial_stats(p_platform_id uuid DEFAULT NULL::uuid)
RETURNS TABLE(
    mrr numeric,
    arr numeric,
    total_revenue_last_30_days numeric,
    new_tenants_last_30_days bigint,
    active_subscriptions bigint,
    payments_last_30_days bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY
    WITH valid_payments AS (
        SELECT 
            (t.amount_in_cents / 100.0) as amount,
            t.created_at,
            ten.id as tenant_id,
            ten.created_at as tenant_created_at,
            ten.platform_id
        FROM public.transactions t
        JOIN public.tenants ten ON t.tenant_id = ten.id
        WHERE t.status IN ('APPROVED', 'COMPLETED') 
          AND t.environment <> 'test'
          AND ten.is_system_owner = FALSE
          AND (p_platform_id IS NULL OR ten.platform_id = p_platform_id)
    ),
    monthly_revenue AS (
        SELECT COALESCE(SUM(amount), 0) as total
        FROM valid_payments
        WHERE created_at >= date_trunc('month', NOW() - interval '1 month')
          AND created_at < date_trunc('month', NOW())
    )
    SELECT
        (SELECT total FROM monthly_revenue) AS mrr,
        (SELECT total * 12 FROM monthly_revenue) AS arr,
        (SELECT COALESCE(SUM(amount), 0) FROM valid_payments WHERE created_at >= NOW() - interval '30 days') AS total_revenue_last_30_days,
        (SELECT COUNT(DISTINCT id) FROM public.tenants WHERE created_at >= NOW() - interval '30 days' AND is_system_owner = FALSE AND (p_platform_id IS NULL OR platform_id = p_platform_id)) AS new_tenants_last_30_days,
        (SELECT COUNT(*) FROM public.tenant_subscriptions ts JOIN public.tenants t ON ts.tenant_id = t.id WHERE (ts.end_date IS NULL OR ts.end_date >= NOW()) AND ts.start_date <= NOW() AND t.is_system_owner = FALSE AND (p_platform_id IS NULL OR t.platform_id = p_platform_id)) AS active_subscriptions,
        (SELECT COUNT(*) FROM valid_payments WHERE created_at >= NOW() - interval '30 days') AS payments_last_30_days;
END;
$$;

-- 2. get_platforms_stats
CREATE OR REPLACE FUNCTION public.get_platforms_stats()
RETURNS TABLE(
    platform_id uuid,
    platform_name text,
    mrr numeric,
    active_subscriptions bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY
    WITH monthly_revenue AS (
        SELECT
            ten.platform_id,
            SUM(t.amount_in_cents / 100.0) as total
        FROM public.transactions t
        JOIN public.tenants ten ON t.tenant_id = ten.id
        WHERE t.status IN ('APPROVED', 'COMPLETED')
          AND t.environment = 'production'
          AND ten.is_system_owner = FALSE
          AND t.created_at >= date_trunc('month', NOW() - interval '1 month')
          AND t.created_at < date_trunc('month', NOW())
        GROUP BY ten.platform_id
    ),
    active_subs AS (
        SELECT
            ten.platform_id,
            COUNT(*) as total
        FROM public.tenant_subscriptions ts
        JOIN public.tenants ten ON ts.tenant_id = ten.id
        WHERE (ts.end_date IS NULL OR ts.end_date >= NOW())
          AND ts.start_date <= NOW()
          AND ten.is_system_owner = FALSE
        GROUP BY ten.platform_id
    )
    SELECT
        p.id as platform_id,
        p.name as platform_name,
        COALESCE(mr.total, 0) as mrr,
        COALESCE(asub.total, 0) as active_subscriptions
    FROM public.platforms p
    LEFT JOIN monthly_revenue mr ON p.id = mr.platform_id
    LEFT JOIN active_subs asub ON p.id = asub.platform_id;
END;
$$;
