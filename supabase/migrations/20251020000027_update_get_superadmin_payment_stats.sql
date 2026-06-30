CREATE OR REPLACE FUNCTION get_superadmin_payment_stats()
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
            p.amount_in_cents / 100.0 as amount,
            t.platform_id,
            p.tenant_id,
            p.created_at
        FROM public.payments p
        JOIN public.tenants t ON p.tenant_id = t.id
        WHERE p.status = 'APPROVED' AND p.environment = 'production'
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
            p.amount_in_cents / 100.0 as amount,
            t.platform_id,
            p.tenant_id,
            p.created_at
        FROM public.payments p
        JOIN public.tenants t ON p.tenant_id = t.id
        WHERE p.status = 'APPROVED' AND p.environment = 'production'
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