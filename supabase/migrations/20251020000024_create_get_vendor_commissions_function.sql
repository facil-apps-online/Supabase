CREATE OR REPLACE FUNCTION get_vendor_commissions(p_user_id uuid)
RETURNS TABLE(
    id text,
    date text,
    productName text,
    saleAmount numeric,
    commissionRate numeric,
    commissionAmount numeric
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- This is a placeholder function.
    -- The actual implementation will depend on the payments table schema.
    -- For now, we return mock data.
    RETURN QUERY
    SELECT
        '1' as id,
        '2025-10-20' as date,
        'Pago de Tenant A (Plataforma X)' as productName,
        100000::numeric as saleAmount,
        50::numeric as commissionRate,
        50000::numeric as commissionAmount
    UNION ALL
    SELECT
        '2' as id,
        '2025-10-20' as date,
        'Pago de Tenant B (Plataforma Y)' as productName,
        50000::numeric as saleAmount,
        10::numeric as commissionRate,
        5000::numeric as commissionAmount;
END;
$$;