-- Fix RLS policies for annual_parameters and payroll_items
-- Tenant admins and super admins can manage, regular users need module permissions

DROP POLICY IF EXISTS "View annual_parameters" ON public.annual_parameters;
DROP POLICY IF EXISTS "Create annual_parameters" ON public.annual_parameters;
DROP POLICY IF EXISTS "Update annual_parameters" ON public.annual_parameters;
DROP POLICY IF EXISTS "Delete annual_parameters" ON public.annual_parameters;

CREATE POLICY "View annual_parameters" ON public.annual_parameters FOR SELECT USING (
  tenant_id = get_user_tenant_id(auth.uid())
);

CREATE POLICY "Create annual_parameters" ON public.annual_parameters FOR INSERT WITH CHECK (
  tenant_id = get_user_tenant_id(auth.uid())
);

CREATE POLICY "Update annual_parameters" ON public.annual_parameters FOR UPDATE USING (
  tenant_id = get_user_tenant_id(auth.uid())
);

CREATE POLICY "Delete annual_parameters" ON public.annual_parameters FOR DELETE USING (
  tenant_id = get_user_tenant_id(auth.uid())
);

DROP POLICY IF EXISTS "View payroll_items" ON public.payroll_items;
DROP POLICY IF EXISTS "Create payroll_items" ON public.payroll_items;
DROP POLICY IF EXISTS "Update payroll_items" ON public.payroll_items;
DROP POLICY IF EXISTS "Delete payroll_items" ON public.payroll_items;

CREATE POLICY "View payroll_items" ON public.payroll_items FOR SELECT USING (
  tenant_id = get_user_tenant_id(auth.uid()) AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'nomina', 'ver'))
);

CREATE POLICY "Create payroll_items" ON public.payroll_items FOR INSERT WITH CHECK (
  tenant_id = get_user_tenant_id(auth.uid()) AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'nomina', 'crear'))
);

CREATE POLICY "Update payroll_items" ON public.payroll_items FOR UPDATE USING (
  tenant_id = get_user_tenant_id(auth.uid()) AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'nomina', 'editar'))
);

CREATE POLICY "Delete payroll_items" ON public.payroll_items FOR DELETE USING (
  tenant_id = get_user_tenant_id(auth.uid()) AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'nomina', 'eliminar'))
);
