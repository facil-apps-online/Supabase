-- La edge function tenant-actions ('archive-branch') llama a archive_branch, que no existía en la BD.
-- Archiva una sucursal (status = 'archived'). El historial lo registra el trigger log_branch_status_change_v2.
CREATE OR REPLACE FUNCTION "public"."archive_branch"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_branch_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_branch record;
BEGIN
    SELECT * INTO v_branch FROM public.branches
    WHERE id = p_branch_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;

    IF v_branch IS NULL THEN
        RAISE EXCEPTION 'Branch not found or you do not have permission to archive it.';
    END IF;
    IF v_branch.is_main_branch THEN
        RAISE EXCEPTION 'Cannot archive the main branch.';
    END IF;

    UPDATE public.branches
    SET status = 'archived'
    WHERE id = p_branch_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;

    RETURN jsonb_build_object('success', true, 'message', 'Branch archived successfully');
END;
$$;

ALTER FUNCTION "public"."archive_branch"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_branch_id" "uuid") OWNER TO "postgres";
GRANT ALL ON FUNCTION "public"."archive_branch"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_branch_id" "uuid") TO "service_role";
