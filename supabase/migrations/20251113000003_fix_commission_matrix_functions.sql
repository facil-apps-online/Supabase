CREATE OR REPLACE FUNCTION get_user_service_commission_matrix(
  user_id_param uuid,
  tenant_id_param uuid
)
RETURNS TABLE(
  service_id uuid,
  service_name text,
  branches json
)
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN QUERY
  WITH tenant_branches AS (
    -- 1. Find all active branches for the tenant
    SELECT id AS branch_id
    FROM public.branches
    WHERE tenant_id = tenant_id_param AND status = 'active'
  ),
  relevant_services AS (
    -- 2. Find all master services available in those branches
    SELECT DISTINCT bs.service_id, s.name as service_name
    FROM public.branch_services bs
    JOIN public.services s ON bs.service_id = s.id
    WHERE bs.branch_id IN (SELECT branch_id FROM tenant_branches)
      AND bs.tenant_id = tenant_id_param
  ),
  commission_matrix AS (
    -- 3. Create the matrix of service/branch combinations for the user
    SELECT
      rs.service_id,
      rs.service_name,
      tb.branch_id,
      b.name as branch_name
    FROM relevant_services rs
    CROSS JOIN tenant_branches tb
    JOIN public.branches b ON tb.branch_id = b.id
    -- Ensure the service is actually in the specific branch of this row
    WHERE EXISTS (
      SELECT 1 FROM public.branch_services bs
      WHERE bs.service_id = rs.service_id AND bs.branch_id = tb.branch_id
    )
  )
  -- 4. Join with commissions and aggregate
  SELECT
    cm.service_id,
    cm.service_name,
    json_agg(
      json_build_object(
        'branch_id', cm.branch_id,
        'branch_name', cm.branch_name,
        'commission_id', sc.id,
        'commission_rate', sc.commission_rate,
        'can_perform', sc.can_perform
      )
    ) as branches
  FROM commission_matrix cm
  LEFT JOIN public.service_user_commissions sc
    ON cm.service_id = sc.service_id
    AND cm.branch_id = sc.branch_id
    AND sc.user_id = user_id_param
  GROUP BY cm.service_id, cm.service_name;
END;
$$;

CREATE OR REPLACE FUNCTION get_user_product_commission_matrix(
  user_id_param uuid,
  tenant_id_param uuid
)
RETURNS TABLE(
  product_id uuid,
  product_name text,
  branches json
)
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN QUERY
  WITH tenant_branches AS (
    -- 1. Find all active branches for the tenant
    SELECT id AS branch_id
    FROM public.branches
    WHERE tenant_id = tenant_id_param AND status = 'active'
  ),
  relevant_products AS (
    -- 2. Find all master products available in those branches
    SELECT DISTINCT bp.product_id, p.name as product_name
    FROM public.branch_products bp
    JOIN public.products p ON bp.product_id = p.id
    WHERE bp.branch_id IN (SELECT branch_id FROM tenant_branches)
      AND bp.tenant_id = tenant_id_param
  ),
  commission_matrix AS (
    -- 3. Create the matrix of product/branch combinations for the user
    SELECT
      rp.product_id,
      rp.product_name,
      tb.branch_id,
      b.name as branch_name
    FROM relevant_products rp
    CROSS JOIN tenant_branches tb
    JOIN public.branches b ON tb.branch_id = b.id
    -- Ensure the product is actually in the specific branch of this row
    WHERE EXISTS (
      SELECT 1 FROM public.branch_products bp
      WHERE bp.product_id = rp.product_id AND bp.branch_id = tb.branch_id
    )
  )
  -- 4. Join with commissions and aggregate
  SELECT
    cm.product_id,
    cm.product_name,
    json_agg(
      json_build_object(
        'branch_id', cm.branch_id,
        'branch_name', cm.branch_name,
        'commission_id', pc.id,
        'commission_rate', pc.commission_rate
      )
    ) as branches
  FROM commission_matrix cm
  LEFT JOIN public.product_user_commissions pc
    ON cm.product_id = pc.product_id
    AND cm.branch_id = pc.branch_id
    AND pc.user_id = user_id_param
  GROUP BY cm.product_id, cm.product_name;
END;
$$;