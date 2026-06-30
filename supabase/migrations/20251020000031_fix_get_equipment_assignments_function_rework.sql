CREATE OR REPLACE FUNCTION "public"."get_equipment_assignments"("p_equipment_id" "uuid") RETURNS TABLE("id" "uuid", "user_name" "text", "branch_name" "text", "assignment_date" "date", "return_date" "date")
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_tenant_id uuid;
BEGIN
    SELECT tenant_id INTO v_tenant_id FROM equipment WHERE id = p_equipment_id;

    RETURN QUERY
    WITH tenant_users AS (
        SELECT
            tu.user_id,
            (tu.first_name || ' ' || tu.last_name) as full_name
        FROM get_tenant_users(v_tenant_id) tu
    )
    SELECT
        ea.id,
        tu.full_name as user_name,
        b.name as branch_name,
        ea.assignment_date,
        ea.return_date
    FROM
        equipment_assignments ea
    JOIN
        tenant_users tu ON ea.user_id = tu.user_id
    JOIN
        branches b ON ea.branch_id = b.id
    WHERE
        ea.equipment_id = p_equipment_id;
END;
$$;

CREATE OR REPLACE FUNCTION "public"."get_equipment_assignments"("p_tenant_id" "uuid", "p_equipment_id" "uuid") RETURNS TABLE("id" "uuid", "user_name" "text", "branch_name" "text", "assignment_date" "date", "return_date" "date")
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY
    WITH tenant_users AS (
        SELECT
            tu.user_id,
            (tu.first_name || ' ' || tu.last_name) as full_name
        FROM get_tenant_users(p_tenant_id) tu
    )
    SELECT
        ea.id,
        tu.full_name as user_name,
        b.name as branch_name,
        ea.assignment_date,
        ea.return_date
    FROM
        equipment_assignments ea
    JOIN
        tenant_users tu ON ea.user_id = tu.user_id
    JOIN
        branches b ON ea.branch_id = b.id
    WHERE
        ea.equipment_id = p_equipment_id AND ea.tenant_id = p_tenant_id;
END;
$$;