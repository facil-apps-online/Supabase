-- Migration: get_vendor_commissions(p_user_id) — el dashboard de comisiones del vendedor
-- (VendorDashboard.tsx) le pega directo a este RPC desde hace tiempo, pero la función nunca
-- se creó (404 en producción). Calcula la comisión real por cada pago aprobado de los tenants
-- que ese vendedor tiene asociados en vendor_tenants, usando la tasa de
-- vendor_platform_commissions — 1er pago vs. recurrente según si es el primer pago exitoso de
-- ese tenant o uno posterior.
--
-- SECURITY DEFINER porque se llama directo desde el cliente (no vía core-actions) con la
-- sesión propia del vendedor, y RLS de vendor_tenants/transactions/vendor_platform_commissions
-- solo permite a super_admin — por eso el chequeo explícito de abajo: cualquier otro usuario
-- solo puede consultar sus propias comisiones (p_user_id = auth.uid()), nunca las de otro.

CREATE OR REPLACE FUNCTION public.get_vendor_commissions(p_user_id uuid)
RETURNS TABLE(
    id uuid,
    date timestamptz,
    "productName" text,
    "saleAmount" numeric,
    "commissionRate" numeric,
    "commissionAmount" numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF p_user_id <> auth.uid() AND NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'No autorizado a consultar las comisiones de otro usuario.';
  END IF;

  RETURN QUERY
  WITH vendor_tenant_ids AS (
    SELECT DISTINCT tenant_id, platform_id FROM public.vendor_tenants WHERE user_id = p_user_id
  ),
  successful_tx AS (
    SELECT
      t.id,
      t.tenant_id,
      t.platform_id,
      t.amount_in_cents,
      COALESCE(t.processed_at, t.created_at) AS paid_at,
      row_number() OVER (PARTITION BY t.tenant_id ORDER BY COALESCE(t.processed_at, t.created_at)) AS payment_seq
    FROM public.transactions t
    JOIN vendor_tenant_ids vti ON vti.tenant_id = t.tenant_id
    WHERE t.status IN ('APPROVED', 'COMPLETED')
  )
  SELECT
    st.id,
    st.paid_at AS date,
    p.name AS "productName",
    ROUND(st.amount_in_cents / 100.0, 2) AS "saleAmount",
    ROUND((CASE WHEN st.payment_seq = 1 THEN vpc.first_payment_commission_rate ELSE vpc.recurring_payment_commission_rate END) * 100, 2) AS "commissionRate",
    ROUND((st.amount_in_cents / 100.0) * (CASE WHEN st.payment_seq = 1 THEN vpc.first_payment_commission_rate ELSE vpc.recurring_payment_commission_rate END), 2) AS "commissionAmount"
  FROM successful_tx st
  JOIN public.vendor_platform_commissions vpc ON vpc.user_id = p_user_id AND vpc.platform_id = st.platform_id
  JOIN public.platforms p ON p.id = st.platform_id
  ORDER BY st.paid_at DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_vendor_commissions(uuid) TO authenticated;
