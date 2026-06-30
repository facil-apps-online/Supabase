CREATE OR REPLACE FUNCTION "public"."get_equipment_assignments"("p_equipment_id" "uuid") RETURNS TABLE("id" "uuid", "user_name" "text", "branch_name" "text", "assignment_date" "date", "return_date" "date")
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        ea.id,
        (u.raw_user_meta_data::jsonb)->>'first_name' || ' ' || (u.raw_user_meta_data::jsonb)->>'last_name' as user_name,
        b.name as branch_name,
        ea.assignment_date,
        ea.return_date
    FROM
        equipment_assignments ea
    JOIN
        auth.users u ON ea.user_id = u.id
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
    SELECT
        ea.id,
        (u.raw_user_meta_data::jsonb)->>'first_name' || ' ' || (u.raw_user_meta_data::jsonb)->>'last_name' as user_name,
        b.name as branch_name,
        ea.assignment_date,
        ea.return_date
    FROM
        equipment_assignments ea
    JOIN
        auth.users u ON ea.user_id = u.id
    JOIN
        branches b ON ea.branch_id = b.id
    WHERE
        ea.equipment_id = p_equipment_id AND ea.tenant_id = p_tenant_id;
END;
$$;