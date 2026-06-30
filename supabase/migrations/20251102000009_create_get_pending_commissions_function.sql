
CREATE OR REPLACE FUNCTION get_pending_commissions(
  p_tenant_id uuid,
  p_branch_id uuid DEFAULT NULL,
  p_user_id uuid DEFAULT NULL
)
RETURNS TABLE(total_pending_commissions numeric) AS $$
BEGIN
  RETURN QUERY
  SELECT
    COALESCE(SUM(commission_amount), 0)
  FROM
    public.earned_commissions
  WHERE
    tenant_id = p_tenant_id
    AND status = 'earned'
    AND (p_branch_id IS NULL OR branch_id = p_branch_id)
    AND (p_user_id IS NULL OR user_id = p_user_id);
END;
$$ LANGUAGE plpgsql;
