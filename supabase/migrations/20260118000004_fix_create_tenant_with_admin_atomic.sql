DROP FUNCTION IF EXISTS create_tenant_with_admin;

CREATE OR REPLACE FUNCTION create_tenant_with_admin(
    p_tenant_id UUID,
    p_user_id UUID,
    p_platform_id UUID,
    p_tenant_name TEXT,
    p_country_id TEXT,
    p_email TEXT,
    p_currency_id UUID,
    p_timezone TEXT,
    p_phone TEXT,
    p_address TEXT,
    p_website TEXT,
    p_latitude NUMERIC,
    p_longitude NUMERIC
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_role_id UUID;
    v_branch_id UUID;
    v_tenant_exists BOOLEAN;
    v_country_uuid UUID;
BEGIN
    -- 1. Validar y convertir country_id
    BEGIN
        v_country_uuid := p_country_id::UUID;
    EXCEPTION WHEN OTHERS THEN
        v_country_uuid := NULL;
    END;

    -- 2. Verificar si el tenant ya existe (considerando PK compuesta id, platform_id)
    SELECT EXISTS(SELECT 1 FROM public.tenants WHERE id = p_tenant_id AND platform_id = p_platform_id) INTO v_tenant_exists;
    
    IF NOT v_tenant_exists THEN
        INSERT INTO public.tenants (
            id,
            platform_id,
            name,
            country_id,
            contact_email,
            contact_phone,
            billing_address,
            website,
            latitude,
            longitude,
            default_currency_id,
            default_timezone,
            subscription_status,
            is_active
        ) VALUES (
            p_tenant_id,
            p_platform_id,
            p_tenant_name,
            v_country_uuid,
            p_email,
            p_phone,
            p_address,
            p_website,
            p_latitude,
            p_longitude,
            p_currency_id,
            p_timezone,
            'trial',
            true
        );
    END IF;

    -- 3. Crear Sucursal Principal si no existe (vinculada al tenant y plataforma)
    SELECT id INTO v_branch_id FROM public.branches 
    WHERE tenant_id = p_tenant_id 
      AND platform_id = p_platform_id 
      AND is_main_branch = true 
    LIMIT 1;

    IF v_branch_id IS NULL THEN
        INSERT INTO public.branches (
            tenant_id,
            platform_id,
            name,
            address,
            is_main_branch,
            status,
            contact_phone,
            commercial_email,
            timezone,
            latitude,
            longitude
        ) VALUES (
            p_tenant_id,
            p_platform_id,
            'Sucursal Principal',
            p_address,
            true,
            'active',
            p_phone,
            p_email,
            p_timezone,
            p_latitude,
            p_longitude
        ) RETURNING id INTO v_branch_id;
    END IF;

    -- 4. Obtener Rol Admin
    SELECT id INTO v_role_id FROM public.roles WHERE name = 'tenant_super_admin' LIMIT 1;
    IF v_role_id IS NULL THEN
        RAISE EXCEPTION 'Rol tenant_super_admin no encontrado';
    END IF;

    -- 5. Asignar Usuario (si no existe asignación previa para este usuario, rol, tenant y plataforma)
    IF NOT EXISTS (
        SELECT 1 FROM public.user_assignments 
        WHERE user_id = p_user_id 
          AND tenant_id = p_tenant_id 
          AND platform_id = p_platform_id 
          AND role_id = v_role_id
    ) THEN
        INSERT INTO public.user_assignments (
            user_id,
            tenant_id,
            platform_id,
            role_id,
            status
        ) VALUES (
            p_user_id,
            p_tenant_id,
            p_platform_id,
            v_role_id,
            'active'
        );
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'tenant_id', p_tenant_id,
        'branch_id', v_branch_id,
        'user_id', p_user_id
    );
END;
$$;

ALTER FUNCTION "public"."create_tenant_with_admin"(UUID, UUID, UUID, TEXT, TEXT, TEXT, UUID, TEXT, TEXT, TEXT, TEXT, NUMERIC, NUMERIC) OWNER TO "postgres";
