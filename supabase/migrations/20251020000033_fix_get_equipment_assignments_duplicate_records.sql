CREATE OR REPLACE FUNCTION "public"."get_equipment_assignments"("p_equipment_id" "uuid") RETURNS TABLE("id" "uuid", "user_name" "text", "branch_name" "text", "assignment_date" "date", "return_date" "date")
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_tenant_id uuid;
BEGIN
    SELECT equipment.tenant_id INTO v_tenant_id FROM public.equipment WHERE equipment.id = p_equipment_id;

    RETURN QUERY
    WITH unique_tenant_users AS (
        SELECT DISTINCT
            tu.user_id,
            (tu.first_name || ' ' || tu.last_name) as full_name
        FROM get_tenant_users(v_tenant_id) tu
    )
    SELECT
        ea.id,
        utu.full_name as user_name,
        b.name as branch_name,
        ea.assignment_date,
        ea.return_date
    FROM
        public.equipment_assignments ea
    JOIN
        unique_tenant_users utu ON ea.user_id = utu.user_id
    JOIN
        public.branches b ON ea.branch_id = b.id
    WHERE
        ea.equipment_id = p_equipment_id;
END;
$$;

CREATE OR REPLACE FUNCTION "public"."get_equipment_assignments"("p_tenant_id" "uuid", "p_equipment_id" "uuid") RETURNS TABLE("id" "uuid", "user_name" "text", "branch_name" "text", "assignment_date" "date", "return_date" "date")
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY
    WITH unique_tenant_users AS (
        SELECT DISTINCT
            tu.user_id,
            (tu.first_name || ' ' || tu.last_name) as full_name
        FROM get_tenant_users(p_tenant_id) tu
    )
    SELECT
        ea.id,
        utu.full_name as user_name,
        b.name as branch_name,
        ea.assignment_date,
        ea.return_date
    FROM
        public.equipment_assignments ea
    JOIN
        unique_tenant_users utu ON ea.user_id = utu.user_id
    JOIN
        public.branches b ON ea.branch_id = b.id
    WHERE
        ea.equipment_id = p_equipment_id AND ea.tenant_id = p_tenant_id;
END;
$$;