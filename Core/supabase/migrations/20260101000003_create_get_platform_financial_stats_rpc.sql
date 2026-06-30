DROP FUNCTION IF EXISTS public.get_platform_financial_stats(p_platform_id uuid);

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
        -- Filtra los pagos completados y de producción, uniéndolos con tenants y plataformas.
        SELECT 
            (pi.amount_in_cents / 100.0) as amount, -- Corregido
            pi.created_at,
            t.id as tenant_id,
            t.created_at as tenant_created_at,
            t.platform_id
        FROM public.payment_intents pi
        JOIN public.tenants t ON pi.tenant_id = t.id
        WHERE pi.status = 'COMPLETED'
          AND pi.environment <> 'test' -- Confirmado
          AND (p_platform_id IS NULL OR t.platform_id = p_platform_id)
    ),
    monthly_revenue AS (
        -- Calcula los ingresos del último mes completo para el MRR.
        SELECT COALESCE(SUM(amount), 0) as total
        FROM valid_payments
        WHERE created_at >= date_trunc('month', NOW() - interval '1 month')
          AND created_at < date_trunc('month', NOW())
    )
    SELECT
        -- MRR: Ingresos del último mes completo.
        (SELECT total FROM monthly_revenue) AS mrr,
        
        -- ARR: MRR multiplicado por 12.
        (SELECT total * 12 FROM monthly_revenue) AS arr,
        
        -- Ingresos totales de los últimos 30 días.
        (SELECT COALESCE(SUM(amount), 0) FROM valid_payments WHERE created_at >= NOW() - interval '30 days') AS total_revenue_last_30_days,
        
        -- Nuevos tenants en los últimos 30 días para la plataforma seleccionada.
        (SELECT COUNT(DISTINCT tenant_id) FROM valid_payments WHERE tenant_created_at >= NOW() - interval '30 days') AS new_tenants_last_30_days,

        -- Suscripciones activas para la plataforma.
        (SELECT COUNT(*) FROM public.tenant_subscriptions ts JOIN public.tenants t ON ts.tenant_id = t.id WHERE ts.is_active = TRUE AND (p_platform_id IS NULL OR t.platform_id = p_platform_id)) AS active_subscriptions,

        -- Conteo de pagos en los últimos 30 días.
        (SELECT COUNT(*) FROM valid_payments WHERE created_at >= NOW() - interval '30 days') AS payments_last_30_days;
END;
$$;
