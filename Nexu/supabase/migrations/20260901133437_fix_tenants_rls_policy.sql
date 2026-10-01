-- Fix RLS policy on tenants to allow reading tenant when user has role in that tenant

-- Drop existing restrictive policy
DROP POLICY IF EXISTS "Users can view their own tenant" ON public.tenants;

-- Create new policy that allows reading tenant if:
-- 1. User is super_admin, OR
-- 2. User has a profile with matching tenant_id, OR  
-- 3. User has a role in that tenant (via user_roles)
CREATE POLICY "Users can view their tenant" ON public.tenants
  FOR SELECT USING (
    public.is_super_admin(auth.uid())
    OR id = public.get_user_tenant_id(auth.uid())
    OR EXISTS (
      SELECT 1 FROM public.user_roles ur
      JOIN public.roles r ON ur.role_id = r.id
      WHERE ur.user_id = auth.uid()
      AND (r.tenant_id = public.tenants.id OR r.tenant_id IS NULL)
    )
  );

-- Also ensure super_admin policy exists
DROP POLICY IF EXISTS "Super admins can manage all tenants" ON public.tenants;
CREATE POLICY "Super admins can manage all tenants" ON public.tenants
  FOR ALL USING (public.is_super_admin(auth.uid()));