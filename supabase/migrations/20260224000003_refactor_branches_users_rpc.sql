-- Migración: Refactorización de funciones RPC del módulo de Sucursales y Usuarios
-- Se maneja la dependencia de RLS, se agrega p_platform_id y se estandarizan filtros.
-- Timestamp: 20260224000003

BEGIN;

--------------------------------------------------------------------------------
-- 0. Manejo de dependencias de RLS
--------------------------------------------------------------------------------
-- Eliminar la política que depende de get_tenant_users
DROP POLICY IF EXISTS "Tenant users can manage their own branch photos" ON public.branch_photos;

--------------------------------------------------------------------------------
-- 1. get_tenant_branches
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_tenant_branches(uuid);
CREATE OR REPLACE FUNCTION public.get_tenant_branches(p_tenant_id uuid, p_platform_id uuid)
 RETURNS SETOF branches
 LANGUAGE sql
 STABLE
AS $function$
    SELECT b.*
    FROM public.branches b
    WHERE b.tenant_id = p_tenant_id AND b.platform_id = p_platform_id
    ORDER BY b.is_main_branch DESC, b.name ASC;
$function$;

--------------------------------------------------------------------------------
-- 2. create_branch
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.create_branch(uuid, text, uuid, text, text, text, text, text, text, text, text, text, text, text, numeric, numeric, text, text);
CREATE OR REPLACE FUNCTION public.create_branch(
    p_tenant_id uuid, 
    p_name text, 
    p_platform_id uuid, 
    p_address text DEFAULT NULL::text, 
    p_description text DEFAULT NULL::text, 
    p_contact_phone text DEFAULT NULL::text, 
    p_whatsapp_phone text DEFAULT NULL::text, 
    p_commercial_email text DEFAULT NULL::text, 
    p_website text DEFAULT NULL::text, 
    p_physical_address_line1 text DEFAULT NULL::text, 
    p_physical_address_line2 text DEFAULT NULL::text, 
    p_physical_city text DEFAULT NULL::text, 
    p_physical_state text DEFAULT NULL::text, 
    p_physical_postal_code text DEFAULT NULL::text, 
    p_latitude numeric DEFAULT NULL::numeric, 
    p_longitude numeric DEFAULT NULL::numeric, 
    p_timezone text DEFAULT NULL::text, 
    p_google_place_id text DEFAULT NULL::text
)
 RETURNS branches
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    new_branch public.branches;
BEGIN
    INSERT INTO public.branches (
        tenant_id, 
        name, 
        platform_id,
        address, 
        description, 
        contact_phone, 
        whatsapp_phone, 
        commercial_email,
        website, 
        physical_address_line1, 
        physical_address_line2, 
        physical_city, 
        physical_state,
        physical_postal_code, 
        latitude, 
        longitude, 
        timezone, 
        is_main_branch, 
        google_place_id
    )
    VALUES (
        p_tenant_id, 
        p_name, 
        p_platform_id,
        p_address, 
        p_description, 
        p_contact_phone, 
        p_whatsapp_phone, 
        p_commercial_email,
        p_website, 
        p_physical_address_line1, 
        p_physical_address_line2, 
        p_physical_city, 
        p_physical_state,
        p_physical_postal_code, 
        p_latitude, 
        p_longitude, 
        p_timezone, 
        false, 
        p_google_place_id
    )
    RETURNING * INTO new_branch;
    RETURN new_branch;
END;
$function$;

--------------------------------------------------------------------------------
-- 3. update_branch
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.update_branch(uuid, uuid, text, text, text, text, text, text, text, text, text, text, text, text, numeric, numeric, text, text);
CREATE OR REPLACE FUNCTION public.update_branch(
    p_branch_id uuid, 
    p_tenant_id uuid, 
    p_platform_id uuid,
    p_name text DEFAULT NULL::text, 
    p_description text DEFAULT NULL::text, 
    p_address text DEFAULT NULL::text, 
    p_contact_phone text DEFAULT NULL::text, 
    p_whatsapp_phone text DEFAULT NULL::text, 
    p_commercial_email text DEFAULT NULL::text, 
    p_website text DEFAULT NULL::text, 
    p_physical_address_line1 text DEFAULT NULL::text, 
    p_physical_address_line2 text DEFAULT NULL::text, 
    p_physical_city text DEFAULT NULL::text, 
    p_physical_state text DEFAULT NULL::text, 
    p_physical_postal_code text DEFAULT NULL::text, 
    p_latitude numeric DEFAULT NULL::numeric, 
    p_longitude numeric DEFAULT NULL::numeric, 
    p_timezone text DEFAULT NULL::text, 
    p_google_place_id text DEFAULT NULL::text
)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
    UPDATE public.branches
    SET
        name = COALESCE(p_name, name),
        description = COALESCE(p_description, description),
        address = COALESCE(p_address, address),
        contact_phone = COALESCE(p_contact_phone, contact_phone),
        whatsapp_phone = COALESCE(p_whatsapp_phone, whatsapp_phone),
        commercial_email = COALESCE(p_commercial_email, commercial_email),
        website = COALESCE(p_website, website),
        physical_address_line1 = COALESCE(p_physical_address_line1, physical_address_line1),
        physical_address_line2 = COALESCE(p_physical_address_line2, physical_address_line2),
        physical_city = COALESCE(p_physical_city, physical_city),
        physical_state = COALESCE(p_physical_state, physical_state),
        physical_postal_code = COALESCE(p_physical_postal_code, physical_postal_code),
        latitude = COALESCE(p_latitude, latitude),
        longitude = COALESCE(p_longitude, longitude),
        timezone = COALESCE(p_timezone, timezone),
        google_place_id = COALESCE(p_google_place_id, google_place_id),
        updated_at = now()
    WHERE id = p_branch_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;
END;
$function$;

--------------------------------------------------------------------------------
-- 4. delete_branch
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.delete_branch(uuid, uuid);
CREATE OR REPLACE FUNCTION public.delete_branch(p_tenant_id uuid, p_platform_id uuid, p_branch_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_caller_role TEXT := (auth.jwt() -> 'app_metadata' ->> 'role');
    v_caller_tenant_id UUID := (auth.jwt() -> 'app_metadata' ->> 'tenant_id')::uuid;
    v_branch record;
BEGIN
    IF v_caller_role NOT IN ('super_admin', 'tenant_super_admin') THEN
        RAISE EXCEPTION 'Permission denied: You do not have rights to delete branches.';
    END IF;
    IF v_caller_role != 'super_admin' AND v_caller_tenant_id != p_tenant_id THEN
        RAISE EXCEPTION 'Permission denied: You can only delete branches within your own tenant.';
    END IF;

    SELECT * INTO v_branch FROM public.branches WHERE id = p_branch_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;
    IF v_branch IS NULL THEN RAISE EXCEPTION 'Branch not found or you do not have permission to delete it.'; END IF;
    IF v_branch.is_main_branch THEN RAISE EXCEPTION 'Cannot delete the main branch.'; END IF;
    
    DELETE FROM public.branches WHERE id = p_branch_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;
    RETURN jsonb_build_object('success', true, 'message', 'Branch deleted successfully');
END;
$function$;

--------------------------------------------------------------------------------
-- 5. get_schedules_for_branch
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_schedules_for_branch(uuid, uuid);
CREATE OR REPLACE FUNCTION public.get_schedules_for_branch(p_tenant_id uuid, p_platform_id uuid, p_branch_id uuid)
 RETURNS SETOF user_schedules
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN QUERY
    SELECT us.*
    FROM public.user_schedules us
    JOIN public.user_assignments tua ON us.user_id = tua.user_id AND us.tenant_id = tua.tenant_id AND us.branch_id = tua.branch_id AND us.platform_id = tua.platform_id
    WHERE
        us.tenant_id = p_tenant_id
        AND us.platform_id = p_platform_id
        AND us.branch_id = p_branch_id
        AND us.is_active = true
        AND tua.is_schedulable = true;
END;
$function$;

--------------------------------------------------------------------------------
-- 6. check_slug_availability
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.check_slug_availability(jsonb);
CREATE OR REPLACE FUNCTION public.check_slug_availability(params jsonb)
 RETURNS boolean
 LANGUAGE plpgsql
AS $function$
DECLARE
    p_slug text := params->>'p_slug';
    p_country_id uuid := (params->>'p_country_id')::uuid;
    p_tenant_id uuid := (params->>'p_tenant_id')::uuid;
    p_platform_id uuid := (params->>'p_platform_id')::uuid;
BEGIN
    IF p_platform_id IS NULL THEN
        SELECT platform_id INTO p_platform_id FROM public.tenants WHERE id = p_tenant_id;
    END IF;

    IF p_platform_id IS NULL THEN
        RAISE EXCEPTION 'Could not determine platform for tenant';
    END IF;

    RETURN NOT EXISTS (
        SELECT 1
        FROM public.tenants
        WHERE slug = p_slug 
          AND country_id = p_country_id
          AND platform_id = p_platform_id
          AND id != p_tenant_id
    );
END;
$function$;

DROP FUNCTION IF EXISTS public.check_slug_availability(text, uuid, uuid);
DROP FUNCTION IF EXISTS public.check_slug_availability(text, uuid, uuid, uuid);
CREATE OR REPLACE FUNCTION public.check_slug_availability(p_slug text, p_country_id uuid, p_tenant_id uuid, p_platform_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN NOT EXISTS (
        SELECT 1
        FROM public.tenants
        WHERE slug = p_slug 
          AND country_id = p_country_id
          AND platform_id = p_platform_id
          AND id != p_tenant_id
    );
END;
$function$;

--------------------------------------------------------------------------------
-- 7. get_tenant_users
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_tenant_users(uuid);
CREATE OR REPLACE FUNCTION public.get_tenant_users(p_target_tenant_id uuid, p_platform_id uuid)
 RETURNS TABLE(assignment_id uuid, user_id uuid, email text, first_name text, last_name text, role_id uuid, role_name text, role_display_name text, branch_id uuid, branch_name text, status text, is_schedulable boolean, avatar_url text, base_salary numeric, default_product_commission_rate numeric, default_service_commission_rate numeric, timezone text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
AS $function$
DECLARE
    v_caller_id UUID := auth.uid();
    v_caller_tenant_ids UUID[];
BEGIN
    SELECT array_agg(DISTINCT ua.tenant_id)
    FROM public.user_assignments ua
    WHERE ua.user_id = v_caller_id AND ua.platform_id = p_platform_id
    INTO v_caller_tenant_ids;

    IF NOT (p_target_tenant_id = ANY(v_caller_tenant_ids)) THEN
        RAISE EXCEPTION 'Access denied: You do not have permission to view users for this tenant.';
    END IF;

    RETURN QUERY
    SELECT
        ua.id AS assignment_id,
        u.id AS user_id,
        COALESCE(u.raw_user_meta_data ->> 'real_email', u.email)::text AS email,
        (u.raw_user_meta_data ->> 'first_name') AS first_name,
        (u.raw_user_meta_data ->> 'last_name') AS last_name,
        r.id as role_id,
        r.name AS role_name,
        r.display_name AS role_display_name,
        ua.branch_id,
        b.name AS branch_name,
        ua.status,
        ua.is_schedulable,
        (u.raw_user_meta_data ->> 'avatar_url') AS avatar_url,
        ua.base_salary,
        ua.default_product_commission_rate,
        ua.default_service_commission_rate,
        (u.raw_user_meta_data ->> 'timezone')::text AS timezone
    FROM
        public.user_assignments ua
    JOIN
        auth.users u ON ua.user_id = u.id
    JOIN
        public.roles r ON ua.role_id = r.id AND ua.platform_id = r.platform_id
    LEFT JOIN
        public.branches b ON ua.branch_id = b.id AND ua.tenant_id = b.tenant_id AND ua.platform_id = b.platform_id
    WHERE
        ua.tenant_id = p_target_tenant_id
        AND ua.platform_id = p_platform_id;
END;
$function$;

--------------------------------------------------------------------------------
-- 8. get_user_assignments
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_user_assignments(uuid, uuid);
CREATE OR REPLACE FUNCTION public.get_user_assignments(p_user_id uuid, p_tenant_id uuid, p_platform_id uuid)
 RETURNS TABLE(assignment_id uuid, user_id uuid, tenant_id uuid, role_id uuid, branch_id uuid, status text, role_name text, role_display_name text, branch_name text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
AS $function$
DECLARE
    v_caller_role TEXT := (auth.jwt() -> 'app_metadata' ->> 'role');
    v_caller_tenant_id UUID := (auth.jwt() -> 'app_metadata' ->> 'tenant_id')::uuid;
BEGIN
    IF v_caller_role NOT IN ('super_admin', 'tenant_super_admin', 'tenant_admin') THEN
        RAISE EXCEPTION 'Access denied.';
    END IF;

    IF v_caller_role != 'super_admin' AND v_caller_tenant_id != p_tenant_id THEN
        RAISE EXCEPTION 'Access denied: You can only view assignments within your own tenant.';
    END IF;

    RETURN QUERY
    SELECT
        ua.id,
        ua.user_id,
        ua.tenant_id,
        ua.role_id,
        ua.branch_id,
        ua.status,
        r.name,
        r.display_name,
        b.name
    FROM
        public.user_assignments ua
    JOIN
        public.roles r ON ua.role_id = r.id AND ua.platform_id = r.platform_id
    LEFT JOIN
        public.branches b ON ua.branch_id = b.id AND ua.tenant_id = b.tenant_id AND ua.platform_id = b.platform_id
    WHERE
        ua.user_id = p_user_id
        AND ua.tenant_id = p_tenant_id
        AND ua.platform_id = p_platform_id;
END;
$function$;

--------------------------------------------------------------------------------
-- 9. Restaurar dependencias de RLS
--------------------------------------------------------------------------------
-- Recrear la política usando la nueva firma de get_tenant_users
CREATE POLICY "Tenant users can manage their own branch photos" ON public.branch_photos
FOR ALL
TO authenticated
USING (
    auth.uid() IN (
        SELECT user_id FROM public.get_tenant_users(tenant_id, platform_id)
    )
);

COMMIT;
