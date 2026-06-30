-- Fix for get_user_service_commission_matrix
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
SECURITY DEFINER
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

-- Fix for get_user_product_commission_matrix
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
SECURITY DEFINER
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

-- Fix for get_branch_commission_matrix
CREATE OR REPLACE FUNCTION get_branch_commission_matrix(
  branch_id_param uuid,
  tenant_id_param uuid
)
RETURNS TABLE(
  item_id uuid,
  item_name text,
  item_type text,
  users json
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  WITH branch_products AS (
    SELECT bp.product_id as id, p.name, 'product' as type
    FROM public.branch_products bp
    JOIN public.products p ON bp.product_id = p.id
    WHERE bp.branch_id = branch_id_param AND bp.tenant_id = tenant_id_param
  ),
  branch_services AS (
    SELECT bs.service_id as id, s.name, 'service' as type
    FROM public.branch_services bs
    JOIN public.services s ON bs.service_id = s.id
    WHERE bs.branch_id = branch_id_param AND bs.tenant_id = tenant_id_param
  ),
  all_items_in_branch AS (
    SELECT id, name, type FROM branch_products
    UNION ALL
    SELECT id, name, type FROM branch_services
  ),
  relevant_users AS (
    SELECT DISTINCT ua.user_id, (u.raw_user_meta_data->>'first_name') || ' ' || (u.raw_user_meta_data->>'last_name') as user_name
    FROM public.user_assignments ua
    JOIN auth.users u ON ua.user_id = u.id
    WHERE ua.tenant_id = tenant_id_param AND ua.status = 'active'
  ),
  commission_matrix AS (
    SELECT
      ai.id as item_id,
      ai.name as item_name,
      ai.type as item_type,
      ru.user_id,
      ru.user_name
    FROM all_items_in_branch ai
    CROSS JOIN relevant_users ru
  )
  SELECT
    cm.item_id,
    cm.item_name,
    cm.item_type,
    json_agg(
      json_build_object(
        'user_id', cm.user_id,
        'user_name', cm.user_name,
        'commission_rate',
          CASE
            WHEN cm.item_type = 'product' THEN pc.commission_rate
            WHEN cm.item_type = 'service' THEN sc.commission_rate
            ELSE NULL
          END,
        'can_perform',
          CASE
            WHEN cm.item_type = 'service' THEN sc.can_perform
            ELSE NULL
          END,
        'commission_id',
          CASE
            WHEN cm.item_type = 'product' THEN pc.id
            WHEN cm.item_type = 'service' THEN sc.id
            ELSE NULL
          END
      )
    )::json as users
  FROM commission_matrix cm
  LEFT JOIN public.product_user_commissions pc
    ON cm.item_id = pc.product_id
    AND cm.user_id = pc.user_id
    AND branch_id_param = pc.branch_id
  LEFT JOIN public.service_user_commissions sc
    ON cm.item_id = sc.service_id
    AND cm.user_id = sc.user_id
    AND branch_id_param = sc.branch_id
  GROUP BY cm.item_id, cm.item_name, cm.item_type;
END;
$$;
