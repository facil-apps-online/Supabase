-- =============================================================
-- 1) user_permissions: los miembros con acceso de administracion
--    de un tenant pueden ver y gestionar los permisos individuales
--    de los usuarios de SU tenant. Antes solo el propio usuario o
--    un super admin podian, por lo que el dialogo "Gestionar Roles
--    y Permisos de Usuario" quedaba roto (estados en blanco y
--    writes rechazados por RLS) para admins de tenant.
--    Sigue el mismo patron de acceso por membresia de tenant ya
--    usado en roles y role_permissions.
-- 2) Re-seed: el modulo unificado "evaluaciones" quedo sin permisos
--    sembrados (0 filas), por lo que nunca aparecia en las matrices
--    de permisos.
-- =============================================================

-- 1a. SELECT: ver permisos individuales de usuarios de mi tenant
DROP POLICY IF EXISTS "Tenant admins can view user permissions for their tenant" ON public.user_permissions;
CREATE POLICY "Tenant admins can view user permissions for their tenant" ON public.user_permissions
    FOR SELECT TO authenticated USING (
        EXISTS (
            SELECT 1 FROM public.profiles p
            WHERE p.user_id = user_permissions.user_id
              AND p.tenant_id = public.get_user_tenant_id(auth.uid())
        )
    );

-- 1b. INSERT: otorgar o revocar (granted = false) permisos de usuarios de mi tenant
CREATE POLICY "Tenant admins can insert user permissions for their tenant" ON public.user_permissions
    FOR INSERT TO authenticated WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.profiles p
            WHERE p.user_id = user_permissions.user_id
              AND p.tenant_id = public.get_user_tenant_id(auth.uid())
        )
    );

-- 1c. DELETE: remover permisos individuales de usuarios de mi tenant
CREATE POLICY "Tenant admins can delete user permissions for their tenant" ON public.user_permissions
    FOR DELETE TO authenticated USING (
        EXISTS (
            SELECT 1 FROM public.profiles p
            WHERE p.user_id = user_permissions.user_id
              AND p.tenant_id = public.get_user_tenant_id(auth.uid())
        )
    );

-- 2a. Permisos del modulo "evaluaciones" (idempotente)
INSERT INTO public.permissions (module_id, action, description)
SELECT m.id, a.action, 'Evaluaciones - ' || a.action::text
FROM public.modules m
CROSS JOIN (VALUES
    ('ver'::permission_action),
    ('crear'::permission_action),
    ('editar'::permission_action),
    ('eliminar'::permission_action),
    ('firmar'::permission_action),
    ('aprobar'::permission_action)
) AS a(action)
WHERE m.code = 'evaluaciones'
ON CONFLICT (module_id, action) DO NOTHING;

-- 2b. Otorgar los permisos nuevos a los roles de sistema existentes
INSERT INTO public.role_permissions (role_id, permission_id)
SELECT r.id, p.id
FROM public.roles r
CROSS JOIN public.permissions p
JOIN public.modules m ON p.module_id = m.id
WHERE r.is_system = true AND m.code = 'evaluaciones'
ON CONFLICT DO NOTHING;
