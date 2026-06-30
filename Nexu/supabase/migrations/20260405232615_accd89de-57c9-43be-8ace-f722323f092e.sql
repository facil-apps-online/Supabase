
-- 1. Create annual_parameters table
CREATE TABLE public.annual_parameters (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  year integer NOT NULL,
  minimum_wage numeric NOT NULL DEFAULT 0,
  transport_allowance numeric NOT NULL DEFAULT 0,
  uvt_value numeric NOT NULL DEFAULT 0,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  created_by uuid,
  UNIQUE(tenant_id, year)
);

ALTER TABLE public.annual_parameters ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View annual_parameters" ON public.annual_parameters FOR SELECT USING (
  tenant_id = get_user_tenant_id(auth.uid()) AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'nomina', 'ver'))
);
CREATE POLICY "Create annual_parameters" ON public.annual_parameters FOR INSERT WITH CHECK (
  tenant_id = get_user_tenant_id(auth.uid()) AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'nomina', 'crear'))
);
CREATE POLICY "Update annual_parameters" ON public.annual_parameters FOR UPDATE USING (
  tenant_id = get_user_tenant_id(auth.uid()) AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'nomina', 'editar'))
);
CREATE POLICY "Delete annual_parameters" ON public.annual_parameters FOR DELETE USING (
  tenant_id = get_user_tenant_id(auth.uid()) AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'nomina', 'eliminar'))
);

-- 2. Create payroll_items table (flexible DEV/DED lines)
CREATE TABLE public.payroll_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  employee_id uuid NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
  period_id uuid NOT NULL REFERENCES public.payroll_periods(id) ON DELETE CASCADE,
  concept text NOT NULL,
  type text NOT NULL CHECK (type IN ('DEV', 'DED')),
  value numeric NOT NULL DEFAULT 0,
  payment_date date,
  notes text,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  created_by uuid
);

ALTER TABLE public.payroll_items ENABLE ROW LEVEL SECURITY;

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
