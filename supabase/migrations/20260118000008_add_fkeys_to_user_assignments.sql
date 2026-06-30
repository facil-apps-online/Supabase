-- 1. Eliminar restricciones previas si existen para evitar conflictos
ALTER TABLE public.user_assignments DROP CONSTRAINT IF EXISTS user_assignments_tenant_fkey;
ALTER TABLE public.user_assignments DROP CONSTRAINT IF EXISTS user_assignments_tenant_id_fkey; -- Nombre alternativo común

ALTER TABLE public.user_assignments DROP CONSTRAINT IF EXISTS user_assignments_role_id_fkey;

ALTER TABLE public.user_assignments DROP CONSTRAINT IF EXISTS user_assignments_branch_fkey;
ALTER TABLE public.user_assignments DROP CONSTRAINT IF EXISTS user_assignments_branch_id_fkey; -- Nombre alternativo común

-- 2. Crear las llaves foráneas corregidas (compuestas)

-- FK compuesta para tenants (id, platform_id)
ALTER TABLE public.user_assignments
ADD CONSTRAINT user_assignments_tenant_fkey
FOREIGN KEY (tenant_id, platform_id) 
REFERENCES public.tenants(id, platform_id) 
ON DELETE CASCADE;

-- FK simple para roles (id)
ALTER TABLE public.user_assignments
ADD CONSTRAINT user_assignments_role_id_fkey
FOREIGN KEY (role_id) 
REFERENCES public.roles(id) 
ON DELETE CASCADE;

-- FK compuesta para branches (id, tenant_id, platform_id)
ALTER TABLE public.user_assignments
ADD CONSTRAINT user_assignments_branch_fkey
FOREIGN KEY (branch_id, tenant_id, platform_id) 
REFERENCES public.branches(id, tenant_id, platform_id) 
ON DELETE CASCADE;
