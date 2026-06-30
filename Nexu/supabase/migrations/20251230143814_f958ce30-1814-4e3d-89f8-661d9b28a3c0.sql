-- Allow tenant admins to view all user roles in their tenant
CREATE POLICY "Tenant admins can view user roles in their tenant"
ON public.user_roles
FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.user_id = user_roles.user_id
    AND p.tenant_id = get_user_tenant_id(auth.uid())
  )
);

-- Allow tenant admins to insert user roles for users in their tenant
CREATE POLICY "Tenant admins can insert user roles"
ON public.user_roles
FOR INSERT
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.user_id = user_roles.user_id
    AND p.tenant_id = get_user_tenant_id(auth.uid())
  )
  AND EXISTS (
    SELECT 1 FROM public.roles r
    WHERE r.id = user_roles.role_id
    AND r.tenant_id = get_user_tenant_id(auth.uid())
  )
);

-- Allow tenant admins to delete user roles for users in their tenant
CREATE POLICY "Tenant admins can delete user roles"
ON public.user_roles
FOR DELETE
USING (
  EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.user_id = user_roles.user_id
    AND p.tenant_id = get_user_tenant_id(auth.uid())
  )
);