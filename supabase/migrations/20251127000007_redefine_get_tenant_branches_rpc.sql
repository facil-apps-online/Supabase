DROP FUNCTION IF EXISTS public.get_tenant_branches(uuid);

CREATE OR REPLACE FUNCTION public.get_tenant_branches(p_tenant_id uuid)
RETURNS SETOF public.branches
LANGUAGE sql
STABLE -- Mark as STABLE as it doesn't modify the database
AS $$
    SELECT b.*
    FROM public.branches b
    WHERE b.tenant_id = p_tenant_id
    ORDER BY b.is_main_branch DESC, b.name ASC;
$$;

COMMENT ON FUNCTION public.get_tenant_branches(uuid) IS 'Returns all branches for a given tenant, dynamically adapting to the current branches table schema.';