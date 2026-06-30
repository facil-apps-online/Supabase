-- This migration fixes the get_attention_datetimes function by adding tenant_id filtering and status filtering.
-- It also changes the function signature, so we must drop the old one first.

DROP FUNCTION IF EXISTS public.get_attention_datetimes(p_branch_id uuid, p_user_id uuid);

CREATE OR REPLACE FUNCTION public.get_attention_datetimes(
    p_tenant_id uuid, -- Added tenant_id
    p_branch_id uuid,
    p_user_id uuid
)
RETURNS TABLE (
    attention_datetime timestamptz,
    status text
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT
        a.attention_datetime,
        a.status
    FROM
        public.attentions a
    WHERE
        a.tenant_id = p_tenant_id -- Added tenant_id filter
        AND a.status NOT IN ('Pagada', 'Cancelada') -- Added status filter
        AND (p_branch_id IS NULL OR a.branch_id = p_branch_id)
        AND (p_user_id IS NULL OR EXISTS (
            SELECT 1
            FROM public.attention_services s
            WHERE s.attention_id = a.id AND s.user_id = p_user_id
        ));
END;
$$;

COMMENT ON FUNCTION public.get_attention_datetimes(uuid, uuid, uuid) IS 'Returns a list of attention datetimes and statuses, filtered by tenant, and excluding completed/canceled ones.';
