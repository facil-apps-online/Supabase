
-- Create payroll_periods table
CREATE TABLE public.payroll_periods (
  id uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  tenant_id uuid NOT NULL REFERENCES public.tenants(id),
  name text NOT NULL,
  start_date date NOT NULL,
  end_date date NOT NULL,
  payment_date date,
  frequency text NOT NULL DEFAULT 'mensual',
  status text NOT NULL DEFAULT 'abierto',
  created_at timestamp with time zone DEFAULT now(),
  updated_at timestamp with time zone DEFAULT now(),
  created_by uuid
);

ALTER TABLE public.payroll_periods ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View payroll_periods" ON public.payroll_periods FOR SELECT USING (
  (tenant_id = get_user_tenant_id(auth.uid())) AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'nomina', 'ver'))
);
CREATE POLICY "Create payroll_periods" ON public.payroll_periods FOR INSERT WITH CHECK (
  (tenant_id = get_user_tenant_id(auth.uid())) AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'nomina', 'crear'))
);
CREATE POLICY "Update payroll_periods" ON public.payroll_periods FOR UPDATE USING (
  (tenant_id = get_user_tenant_id(auth.uid())) AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'nomina', 'editar'))
);
CREATE POLICY "Delete payroll_periods" ON public.payroll_periods FOR DELETE USING (
  (tenant_id = get_user_tenant_id(auth.uid())) AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'nomina', 'eliminar'))
);

-- Add period_id to payroll_records and drop period_year/period_month
ALTER TABLE public.payroll_records ADD COLUMN period_id uuid REFERENCES public.payroll_periods(id);
ALTER TABLE public.payroll_records DROP COLUMN period_year;
ALTER TABLE public.payroll_records DROP COLUMN period_month;
