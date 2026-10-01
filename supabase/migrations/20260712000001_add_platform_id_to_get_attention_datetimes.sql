-- Migration: 20260712000001_add_platform_id_to_get_attention_datetimes.sql
-- Description: Updates the get_attention_datetimes RPC to accept and filter by p_platform_id.

DROP FUNCTION IF EXISTS public.get_attention_datetimes(p_tenant_id uuid, p_branch_id uuid, p_user_id uuid);
DROP FUNCTION IF EXISTS public.get_attention_datetimes(p_branch_id uuid, p_user_id uuid);

CREATE OR REPLACE FUNCTION public.get_attention_datetimes(
    p_tenant_id uuid,
    p_platform_id uuid,
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
        a.tenant_id = p_tenant_id 
        AND a.platform_id = p_platform_id
        AND a.status NOT IN ('Pagada', 'Cancelada')
        AND (p_branch_id IS NULL OR a.branch_id = p_branch_id)
        AND (p_user_id IS NULL OR EXISTS (
            SELECT 1
            FROM public.attention_services s
            WHERE s.attention_id = a.id AND s.user_id = p_user_id
        ));
END;
$$;

COMMENT ON FUNCTION public.get_attention_datetimes(uuid, uuid, uuid, uuid) IS 'Returns a list of attention datetimes and statuses, filtered by tenant and platform, excluding completed/canceled ones.';
