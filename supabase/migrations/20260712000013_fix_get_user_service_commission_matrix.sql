-- Migration: 20260712000013_fix_get_user_service_commission_matrix.sql

DROP FUNCTION IF EXISTS "public"."get_user_service_commission_matrix"("user_id_param" "uuid", "tenant_id_param" "uuid");
DROP FUNCTION IF EXISTS "public"."get_user_service_commission_matrix"(p_user_id uuid, p_tenant_id uuid);

CREATE OR REPLACE FUNCTION "public"."get_user_service_commission_matrix"("p_user_id" "uuid", "p_tenant_id" "uuid", "p_platform_id" "uuid" DEFAULT NULL) RETURNS TABLE("service_id" "uuid", "service_name" "text", "branches" json)
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
  relevant_services AS (
    -- 2. Find all master services available in those branches
    SELECT DISTINCT bs.service_id, s.name as service_name
    FROM public.branch_services bs
    JOIN public.services s ON bs.service_id = s.id
    WHERE bs.branch_id IN (SELECT branch_id FROM tenant_branches)
      AND bs.tenant_id = p_tenant_id
      -- TODO: AND bs.platform_id = p_platform_id
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
    AND sc.user_id = p_user_id
  GROUP BY cm.service_id, cm.service_name;
END;
$$;
