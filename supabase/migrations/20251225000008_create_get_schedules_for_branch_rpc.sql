CREATE OR REPLACE FUNCTION get_schedules_for_branch(p_tenant_id uuid, p_branch_id uuid)
RETURNS SETOF user_schedules
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT us.*
    FROM public.user_schedules us
    JOIN public.tenant_user_assignments tua ON us.user_id = tua.user_id AND us.tenant_id = tua.tenant_id AND us.branch_id = tua.branch_id
    WHERE
        us.tenant_id = p_tenant_id
        AND us.branch_id = p_branch_id
        AND us.is_active = true
        AND tua.is_schedulable = true; -- Only include schedules for schedulable users
END;
$$;
