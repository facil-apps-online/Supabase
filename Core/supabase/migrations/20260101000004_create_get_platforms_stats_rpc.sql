DROP FUNCTION IF EXISTS public.get_platforms_stats();

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
            t.platform_id,
            SUM(p.amount_in_cents / 100.0) as total
        FROM public.payments p
        JOIN public.tenants t ON p.tenant_id = t.id
        WHERE p.status = 'APPROVED'
          AND p.environment = 'production'
          AND p.created_at >= date_trunc('month', NOW() - interval '1 month')
          AND p.created_at < date_trunc('month', NOW())
        GROUP BY t.platform_id
    ),
    active_subs AS (
        SELECT
            t.platform_id,
            COUNT(*) as total
        FROM public.tenant_subscriptions ts
        JOIN public.tenants t ON ts.tenant_id = t.id
        WHERE ts.is_active = TRUE
        GROUP BY t.platform_id
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
