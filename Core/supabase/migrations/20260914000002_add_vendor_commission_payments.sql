-- Liquidación de comisiones de vendedor. get_vendor_commissions solo CALCULABA en vivo lo que
-- se le debe a un vendedor; no existía forma de marcar una comisión como ya pagada. Esta
-- migración agrega esa capa sin tocar el cálculo original: una fila en
-- vendor_commission_payments por cada (transacción, vendedor) que ya se liquidó.

CREATE TABLE public.vendor_commission_payments (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id             uuid NOT NULL,
  platform_id         uuid NOT NULL REFERENCES public.platforms(id),
  transaction_id      uuid NOT NULL REFERENCES public.transactions(id),
  commission_amount   numeric NOT NULL,
  reference           text,
  paid_by             uuid,
  paid_at             timestamptz NOT NULL DEFAULT now(),
  created_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (transaction_id, user_id)
);

CREATE INDEX idx_vendor_commission_payments_user ON public.vendor_commission_payments (user_id);

ALTER TABLE public.vendor_commission_payments ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Allow ALL for super_admin" ON public.vendor_commission_payments USING (is_super_admin()) WITH CHECK (is_super_admin());

-- get_vendor_commissions: mismo cálculo de siempre (dashboard del propio vendedor), ahora
-- expone si cada comisión ya fue liquidada. DROP primero porque cambia el tipo de retorno
-- (columnas nuevas), CREATE OR REPLACE no lo permite.
DROP FUNCTION IF EXISTS public.get_vendor_commissions(uuid);
CREATE OR REPLACE FUNCTION public.get_vendor_commissions(p_user_id uuid)
RETURNS TABLE(
    id uuid,
    date timestamptz,
    "productName" text,
    "saleAmount" numeric,
    "commissionRate" numeric,
    "commissionAmount" numeric,
    "isPaid" boolean,
    "paidAt" timestamptz
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
    ROUND((st.amount_in_cents / 100.0) * (CASE WHEN st.payment_seq = 1 THEN vpc.first_payment_commission_rate ELSE vpc.recurring_payment_commission_rate END), 2) AS "commissionAmount",
    (vcp.id IS NOT NULL) AS "isPaid",
    vcp.paid_at AS "paidAt"
  FROM successful_tx st
  JOIN public.vendor_platform_commissions vpc ON vpc.user_id = p_user_id AND vpc.platform_id = st.platform_id
  JOIN public.platforms p ON p.id = st.platform_id
  LEFT JOIN public.vendor_commission_payments vcp ON vcp.transaction_id = st.id AND vcp.user_id = p_user_id
  ORDER BY st.paid_at DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_vendor_commissions(uuid) TO authenticated;

-- get_vendor_commissions_admin: mismo cálculo pero sin el candado de auth.uid() = p_user_id
-- (para que un admin pueda ver/liquidar las comisiones de CUALQUIER vendedor, o de todos a la
-- vez) y con nombre/correo del vendedor resueltos. A propósito SIN GRANT a "authenticated":
-- solo se puede invocar vía core-actions con el cliente de service role — el control de acceso
-- real (super_admin/app_super_admin) lo hace core-actions por JWT, igual que el resto de
-- acciones administrativas.
CREATE OR REPLACE FUNCTION public.get_vendor_commissions_admin(
  p_vendor_user_id uuid DEFAULT NULL,
  p_platform_id uuid DEFAULT NULL,
  p_only_pending boolean DEFAULT false
)
RETURNS TABLE(
    id uuid,
    vendor_user_id uuid,
    vendor_name text,
    vendor_email text,
    platform_id uuid,
    platform_name text,
    date timestamptz,
    "saleAmount" numeric,
    "commissionRate" numeric,
    "commissionAmount" numeric,
    "isPaid" boolean,
    "paidAt" timestamptz,
    reference text
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  WITH successful_tx AS (
    SELECT
      t.id,
      t.tenant_id,
      t.platform_id,
      t.amount_in_cents,
      COALESCE(t.processed_at, t.created_at) AS paid_at,
      row_number() OVER (PARTITION BY t.tenant_id ORDER BY COALESCE(t.processed_at, t.created_at)) AS payment_seq
    FROM public.transactions t
    WHERE t.status IN ('APPROVED', 'COMPLETED')
  ),
  vendor_tx AS (
    SELECT DISTINCT vt.user_id AS vendor_user_id, st.*
    FROM successful_tx st
    JOIN public.vendor_tenants vt ON vt.tenant_id = st.tenant_id AND vt.platform_id = st.platform_id
  )
  SELECT
    vtx.id,
    vtx.vendor_user_id,
    NULLIF(TRIM((u.raw_user_meta_data->>'first_name') || ' ' || (u.raw_user_meta_data->>'last_name')), ''),
    u.email::text,
    vtx.platform_id,
    p.name,
    vtx.paid_at AS date,
    ROUND(vtx.amount_in_cents / 100.0, 2) AS "saleAmount",
    ROUND((CASE WHEN vtx.payment_seq = 1 THEN vpc.first_payment_commission_rate ELSE vpc.recurring_payment_commission_rate END) * 100, 2) AS "commissionRate",
    ROUND((vtx.amount_in_cents / 100.0) * (CASE WHEN vtx.payment_seq = 1 THEN vpc.first_payment_commission_rate ELSE vpc.recurring_payment_commission_rate END), 2) AS "commissionAmount",
    (vcp.id IS NOT NULL) AS "isPaid",
    vcp.paid_at AS "paidAt",
    vcp.reference
  FROM vendor_tx vtx
  JOIN public.vendor_platform_commissions vpc ON vpc.user_id = vtx.vendor_user_id AND vpc.platform_id = vtx.platform_id
  JOIN public.platforms p ON p.id = vtx.platform_id
  JOIN auth.users u ON u.id = vtx.vendor_user_id
  LEFT JOIN public.vendor_commission_payments vcp ON vcp.transaction_id = vtx.id AND vcp.user_id = vtx.vendor_user_id
  WHERE (p_vendor_user_id IS NULL OR vtx.vendor_user_id = p_vendor_user_id)
    AND (p_platform_id IS NULL OR vtx.platform_id = p_platform_id)
    AND (NOT p_only_pending OR vcp.id IS NULL)
  ORDER BY vtx.paid_at DESC;
END;
$$;
