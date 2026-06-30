-- Fix Payment Stats RPCs to use the new transactions table
-- Timestamp: 20260119000002

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
        -- Filtra los pagos completados y de producción, uniéndolos con tenants y plataformas.
        -- Updated to use 'transactions' table
        SELECT 
            (t.amount_in_cents / 100.0) as amount,
            t.created_at,
            ten.id as tenant_id,
            ten.created_at as tenant_created_at,
            ten.platform_id
        FROM public.transactions t
        JOIN public.tenants ten ON t.tenant_id = ten.id
        WHERE t.status IN ('APPROVED', 'COMPLETED') -- Support both legacy and new status
          AND t.environment <> 'test'
          AND (p_platform_id IS NULL OR ten.platform_id = p_platform_id)
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
        WHERE ts.is_active = TRUE
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

-- 3. get_superadmin_payment_stats
CREATE OR REPLACE FUNCTION public.get_superadmin_payment_stats()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    investor_payouts jsonb;
    vendor_commissions jsonb;
BEGIN
    WITH approved_payments AS (
        SELECT
            tr.amount_in_cents / 100.0 as amount,
            ten.platform_id,
            tr.tenant_id,
            tr.created_at
        FROM public.transactions tr
        JOIN public.tenants ten ON tr.tenant_id = ten.id
        WHERE tr.status IN ('APPROVED', 'COMPLETED') AND tr.environment = 'production'
    )
    SELECT jsonb_agg(t)
    INTO investor_payouts
    FROM (
        SELECT
            ap.platform_id,
            p.name as platform_name,
            ips.user_id as investor_id,
            u.email as investor_email,
            SUM(ap.amount * ips.investment_share) as total_payout
        FROM approved_payments ap
        JOIN public.investor_platform_shares ips ON ap.platform_id = ips.platform_id
        JOIN public.platforms p ON ap.platform_id = p.id
        JOIN auth.users u ON ips.user_id = u.id
        GROUP BY ap.platform_id, p.name, ips.user_id, u.email
    ) t;

    WITH approved_payments AS (
        SELECT
            tr.amount_in_cents / 100.0 as amount,
            ten.platform_id,
            tr.tenant_id,
            tr.created_at
        FROM public.transactions tr
        JOIN public.tenants ten ON tr.tenant_id = ten.id
        WHERE tr.status IN ('APPROVED', 'COMPLETED') AND tr.environment = 'production'
    ),
    ranked_payments AS (
        SELECT
            *,
            ROW_NUMBER() OVER(PARTITION BY tenant_id ORDER BY created_at) as rn
        FROM approved_payments
    )
    SELECT jsonb_agg(t)
    INTO vendor_commissions
    FROM (
        SELECT
            rp.platform_id,
            p.name as platform_name,
            vpc.user_id as vendor_id,
            u.email as vendor_email,
            SUM(
                CASE
                    WHEN rp.rn = 1 THEN rp.amount * vpc.first_payment_commission_rate
                    ELSE rp.amount * vpc.recurring_payment_commission_rate
                END
            ) as total_commission
        FROM ranked_payments rp
        JOIN public.vendor_platform_commissions vpc ON rp.platform_id = vpc.platform_id
        JOIN public.platforms p ON rp.platform_id = p.id
        JOIN auth.users u ON vpc.user_id = u.id
        GROUP BY rp.platform_id, p.name, vpc.user_id, u.email
    ) t;

    RETURN jsonb_build_object(
        'investor_payouts', COALESCE(investor_payouts, '[]'::jsonb),
        'vendor_commissions', COALESCE(vendor_commissions, '[]'::jsonb)
    );
END;
$$;
