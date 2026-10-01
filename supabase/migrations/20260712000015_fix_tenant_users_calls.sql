-- Migration: 20260712000015_fix_tenant_users_calls.sql
-- Description: Fix inner calls to get_tenant_users that were missing p_platform_id after Part 1 migration.

-- 1. Fix get_equipment (Overload 2)
DROP FUNCTION IF EXISTS "public"."get_equipment"("p_tenant_id" "uuid", "p_search_term" "text", "p_show_inactive" boolean, "p_type_id" "uuid", "p_brand_id" "uuid", "p_platform_id" "uuid");

CREATE OR REPLACE FUNCTION "public"."get_equipment"("p_tenant_id" "uuid", "p_search_term" "text" DEFAULT NULL::"text", "p_show_inactive" boolean DEFAULT false, "p_type_id" "uuid" DEFAULT NULL::"uuid", "p_brand_id" "uuid" DEFAULT NULL::"uuid", "p_platform_id" "uuid" DEFAULT NULL::uuid) RETURNS TABLE("id" "uuid", "name" "text", "type_id" "uuid", "brand_id" "uuid", "is_active" boolean, "type_name" "text", "brand_name" "text", "model" "text", "serial_number" "text", "purchase_date" "text", "last_maintenance_date" "text", "maintenance_frequency" integer, "maintenance_frequency_unit" "text", "notes" "text", "assigned_user_name" "text", "branch_name" "text")
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY
    WITH tenant_users AS (
        SELECT
            tu.user_id,
            (tu.first_name || ' ' || tu.last_name) as full_name
        FROM get_tenant_users(p_tenant_id, p_platform_id) tu
    )
    SELECT
        e.id,
        e.name,
        e.type_id,
        e.brand_id,
        e.is_active,
        et.name as type_name,
        eb.name as brand_name,
        e.model,
        e.serial_number,
        to_char(e.purchase_date, 'YYYY-MM-DD') as purchase_date,
        to_char(e.last_maintenance_date, 'YYYY-MM-DD') as last_maintenance_date,
        e.maintenance_frequency,
        e.maintenance_frequency_unit,
        e.notes,
        tu.full_name as assigned_user_name,
        b.name as branch_name
    FROM
        equipment e
    LEFT JOIN
        equipment_types et ON e.type_id = et.id
    LEFT JOIN
        equipment_brands eb ON e.brand_id = eb.id
    LEFT JOIN
        equipment_assignments ea ON e.id = ea.equipment_id AND ea.return_date IS NULL
    LEFT JOIN
        tenant_users tu ON ea.user_id = tu.user_id
    LEFT JOIN
        branches b ON ea.branch_id = b.id
    WHERE
        e.tenant_id = p_tenant_id
        AND (p_search_term IS NULL OR p_search_term = '' OR e.name ILIKE '%' || p_search_term || '%' OR e.serial_number ILIKE '%' || p_search_term || '%')
        AND (p_show_inactive OR e.is_active = TRUE)
        AND (p_type_id IS NULL OR e.type_id = p_type_id)
        AND (p_brand_id IS NULL OR e.brand_id = p_brand_id);
END;
$$;

-- 2. Fix get_equipment_assignments (Overload 1)
DROP FUNCTION IF EXISTS "public"."get_equipment_assignments"("p_equipment_id" "uuid");
DROP FUNCTION IF EXISTS "public"."get_equipment_assignments"("p_equipment_id" "uuid", "p_platform_id" "uuid");

CREATE OR REPLACE FUNCTION "public"."get_equipment_assignments"("p_equipment_id" "uuid", "p_platform_id" "uuid" DEFAULT NULL::uuid) RETURNS TABLE("id" "uuid", "user_name" "text", "branch_name" "text", "assignment_date" "date", "return_date" "date")
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
        FROM get_tenant_users(v_tenant_id, p_platform_id) tu
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

-- 3. Fix get_equipment_assignments (Overload 2)
DROP FUNCTION IF EXISTS "public"."get_equipment_assignments"("p_tenant_id" "uuid", "p_equipment_id" "uuid");
DROP FUNCTION IF EXISTS "public"."get_equipment_assignments"("p_tenant_id" "uuid", "p_equipment_id" "uuid", "p_platform_id" "uuid");

CREATE OR REPLACE FUNCTION "public"."get_equipment_assignments"("p_tenant_id" "uuid", "p_equipment_id" "uuid", "p_platform_id" "uuid" DEFAULT NULL::uuid) RETURNS TABLE("id" "uuid", "user_name" "text", "branch_name" "text", "assignment_date" "date", "return_date" "date")
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY
    WITH unique_tenant_users AS (
        SELECT DISTINCT
            tu.user_id,
            (tu.first_name || ' ' || tu.last_name) as full_name
        FROM get_tenant_users(p_tenant_id, p_platform_id) tu
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
