-- Migration: 20260712000012_fix_get_user_product_commission_matrix.sql

DROP FUNCTION IF EXISTS "public"."get_user_product_commission_matrix"("user_id_param" "uuid", "tenant_id_param" "uuid");
DROP FUNCTION IF EXISTS "public"."get_user_product_commission_matrix"(p_user_id uuid, p_tenant_id uuid);

CREATE OR REPLACE FUNCTION "public"."get_user_product_commission_matrix"("p_user_id" "uuid", "p_tenant_id" "uuid", "p_platform_id" "uuid" DEFAULT NULL) RETURNS TABLE("product_id" "uuid", "product_name" "text", "branches" json)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  RETURN QUERY
  WITH tenant_branches AS (
    -- 1. Find all active branches for the tenant
    SELECT id AS branch_id
    FROM public.branches
    WHERE tenant_id = p_tenant_id AND status = 'active'
    -- TODO: AND platform_id = p_platform_id
  ),
  relevant_products AS (
    -- 2. Find all master products available in those branches
    SELECT DISTINCT bp.product_id, p.name as product_name
    FROM public.branch_products bp
    JOIN public.products p ON bp.product_id = p.id
    WHERE bp.branch_id IN (SELECT branch_id FROM tenant_branches)
      AND bp.tenant_id = p_tenant_id
      -- TODO: AND bp.platform_id = p_platform_id
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
    AND pc.user_id = p_user_id
  GROUP BY cm.product_id, cm.product_name;
END;
$$;
