-- Fix: System roles should be global (tenant_id = NULL), not per-tenant

-- 0. Allow NULL tenant_id for global roles
ALTER TABLE public.roles ALTER COLUMN tenant_id DROP NOT NULL;

-- 1. Update existing system roles to be global (tenant_id = NULL)
-- Keep only one instance of each system role per platform
-- First, identify the system roles that should be global
UPDATE public.roles 
SET tenant_id = NULL 
WHERE is_system = true 
AND name IN ('Administrador', 'Super Admin', 'Administrador del sistema')
AND tenant_id IS NOT NULL;

-- 2. Remove duplicate system roles per tenant (keep one global, delete tenant-specific duplicates)
-- This CTE identifies duplicate system roles per tenant that should be removed
WITH duplicates AS (
  SELECT id, ROW_NUMBER() OVER (PARTITION BY name ORDER BY created_at) as rn
  FROM public.roles 
  WHERE is_system = true 
  AND name IN ('Administrador', 'Super Admin', 'Administrador del sistema')
)
DELETE FROM public.roles 
WHERE id IN (SELECT id FROM duplicates WHERE rn > 1);

-- 3. Update RLS policy on roles to allow reading global roles (tenant_id IS NULL)
DROP POLICY IF EXISTS "Tenant admins can manage their roles" ON public.roles;
CREATE POLICY "Tenant admins can manage their roles" ON public.roles
  FOR ALL USING (
    tenant_id = public.get_user_tenant_id(auth.uid()) 
    OR tenant_id IS NULL
  );

DROP POLICY IF EXISTS "Super admins can manage all roles" ON public.roles;
CREATE POLICY "Super admins can manage all roles" ON public.roles
  FOR ALL USING (public.is_super_admin(auth.uid()));

DROP POLICY IF EXISTS "Users can view role permissions for their tenant" ON public.role_permissions;
CREATE POLICY "Users can view role permissions for their tenant" ON public.role_permissions
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.roles r
      WHERE r.id = role_id 
      AND (r.tenant_id = public.get_user_tenant_id(auth.uid()) OR r.tenant_id IS NULL)
    )
  );

-- 4. Update create_tenant_with_admin to use global system roles
DROP FUNCTION IF EXISTS public.create_tenant_with_admin(uuid, uuid, uuid, text, text, text, uuid, text, text, text, text, numeric, numeric, text, text, text, text, text, text, text, text, text);

CREATE OR REPLACE FUNCTION public.create_tenant_with_admin(
    p_tenant_id UUID,
    p_user_id UUID,
    p_platform_id UUID,
    p_tenant_name TEXT,
    p_country_id TEXT DEFAULT NULL,
    p_email TEXT DEFAULT NULL,
    p_currency_id UUID DEFAULT NULL,
    p_timezone TEXT DEFAULT NULL,
    p_phone TEXT DEFAULT NULL,
    p_address TEXT DEFAULT NULL,
    p_website TEXT DEFAULT NULL,
    p_latitude NUMERIC DEFAULT NULL,
    p_longitude NUMERIC DEFAULT NULL,
    p_whatsapp_phone TEXT DEFAULT NULL,
    p_legal_name TEXT DEFAULT NULL,
    p_tax_id TEXT DEFAULT NULL,
    p_einvoicing_email TEXT DEFAULT NULL,
    p_physical_address_line1 TEXT DEFAULT NULL,
    p_physical_address_line2 TEXT DEFAULT NULL,
    p_physical_city TEXT DEFAULT NULL,
    p_physical_state TEXT DEFAULT NULL,
    p_physical_postal_code TEXT DEFAULT NULL,
    p_default_language_code TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_role_id UUID;
    v_tenant_exists BOOLEAN;
    v_country_uuid UUID;
BEGIN
    -- 1. Validar y convertir country_id
    BEGIN
        v_country_uuid := p_country_id::UUID;
    EXCEPTION WHEN OTHERS THEN
        v_country_uuid := NULL;
    END;

    -- 2. Verificar si el tenant ya existe
    SELECT EXISTS(SELECT 1 FROM public.tenants WHERE id = p_tenant_id AND platform_id = p_platform_id) INTO v_tenant_exists;
    
    IF NOT v_tenant_exists THEN
        INSERT INTO public.tenants (
            id, platform_id, name, country_id, contact_email, contact_phone,
            whatsapp_phone, billing_address, website, latitude, longitude,
            default_currency_id, default_timezone, subscription_status, is_active,
            legal_name, tax_id, einvoicing_email, physical_address_line1,
            physical_address_line2, physical_city, physical_state,
            physical_postal_code, default_language_code
        ) VALUES (
            p_tenant_id, p_platform_id, p_tenant_name, v_country_uuid, p_email, p_phone,
            p_whatsapp_phone, p_address, p_website, p_latitude, p_longitude,
            p_currency_id, p_timezone, 'trial', true,
            p_legal_name, p_tax_id, p_einvoicing_email, p_physical_address_line1,
            p_physical_address_line2, p_physical_city, p_physical_state,
            p_physical_postal_code, p_default_language_code
        );
    END IF;

    -- 3. Crear Perfil de Usuario si no existe
    IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE user_id = p_user_id) THEN
        INSERT INTO public.profiles (user_id, email, tenant_id, is_super_admin)
        VALUES (p_user_id, p_email, p_tenant_id, false);
    END IF;

    -- 4. Obtener Rol Administrador GLOBAL (tenant_id IS NULL)
    SELECT id INTO v_role_id FROM public.roles 
    WHERE name = 'Administrador' AND tenant_id IS NULL 
    LIMIT 1;
    
    IF v_role_id IS NULL THEN
        INSERT INTO public.roles (tenant_id, name, description, is_system)
        VALUES (NULL, 'Administrador', 'Administrador del sistema', true)
        RETURNING id INTO v_role_id;
    END IF;

    -- 5. Asignar Rol al Usuario
    IF NOT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = p_user_id AND role_id = v_role_id) THEN
        INSERT INTO public.user_roles (user_id, role_id)
        VALUES (p_user_id, v_role_id);
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'tenant_id', p_tenant_id,
        'user_id', p_user_id
    );
END;
$$;

-- Grants already exist from original function creation, no need to re-grant