-- Add policy for tenant admins to insert role permissions for their tenant's roles
CREATE POLICY "Tenant admins can insert role permissions"
ON public.role_permissions
FOR INSERT
WITH CHECK (
  EXISTS (
    SELECT 1 FROM roles r
    WHERE r.id = role_id
    AND r.tenant_id = get_user_tenant_id(auth.uid())
  )
);

-- Add policy for tenant admins to delete role permissions for their tenant's roles
CREATE POLICY "Tenant admins can delete role permissions"
ON public.role_permissions
FOR DELETE
USING (
  EXISTS (
    SELECT 1 FROM roles r
    WHERE r.id = role_permissions.role_id
    AND r.tenant_id = get_user_tenant_id(auth.uid())
  )
);