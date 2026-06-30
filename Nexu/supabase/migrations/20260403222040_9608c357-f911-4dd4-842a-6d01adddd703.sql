
-- ==============================
-- MÓDULO DE NÓMINA
-- ==============================

-- Contratos de empleados
CREATE TABLE public.employee_contracts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id),
  employee_id uuid NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
  contract_type text NOT NULL DEFAULT 'indefinido',
  start_date date NOT NULL,
  end_date date,
  base_salary numeric NOT NULL DEFAULT 0,
  currency text NOT NULL DEFAULT 'COP',
  payment_frequency text NOT NULL DEFAULT 'mensual',
  position text,
  department text,
  work_hours_per_week integer DEFAULT 48,
  active boolean DEFAULT true,
  observations text,
  created_by uuid,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

ALTER TABLE public.employee_contracts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View employee_contracts" ON public.employee_contracts
  FOR SELECT TO public
  USING (tenant_id = get_user_tenant_id(auth.uid()) AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'nomina', 'ver')));

CREATE POLICY "Create employee_contracts" ON public.employee_contracts
  FOR INSERT TO public
  WITH CHECK (tenant_id = get_user_tenant_id(auth.uid()) AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'nomina', 'crear')));

CREATE POLICY "Update employee_contracts" ON public.employee_contracts
  FOR UPDATE TO public
  USING (tenant_id = get_user_tenant_id(auth.uid()) AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'nomina', 'editar')));

CREATE POLICY "Delete employee_contracts" ON public.employee_contracts
  FOR DELETE TO public
  USING (tenant_id = get_user_tenant_id(auth.uid()) AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'nomina', 'eliminar')));

-- Registros de nómina mensual
CREATE TABLE public.payroll_records (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id),
  employee_id uuid NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
  contract_id uuid REFERENCES public.employee_contracts(id),
  period_year integer NOT NULL,
  period_month integer NOT NULL,
  base_salary numeric NOT NULL DEFAULT 0,
  transport_allowance numeric DEFAULT 0,
  overtime numeric DEFAULT 0,
  bonuses numeric DEFAULT 0,
  commissions numeric DEFAULT 0,
  other_earnings numeric DEFAULT 0,
  health_deduction numeric DEFAULT 0,
  pension_deduction numeric DEFAULT 0,
  tax_deduction numeric DEFAULT 0,
  other_deductions numeric DEFAULT 0,
  total_earnings numeric GENERATED ALWAYS AS (base_salary + transport_allowance + overtime + bonuses + commissions + other_earnings) STORED,
  total_deductions numeric GENERATED ALWAYS AS (health_deduction + pension_deduction + tax_deduction + other_deductions) STORED,
  net_pay numeric GENERATED ALWAYS AS (base_salary + transport_allowance + overtime + bonuses + commissions + other_earnings - health_deduction - pension_deduction - tax_deduction - other_deductions) STORED,
  payment_date date,
  status text NOT NULL DEFAULT 'borrador',
  notes text,
  created_by uuid,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  UNIQUE (tenant_id, employee_id, period_year, period_month)
);

ALTER TABLE public.payroll_records ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View payroll_records" ON public.payroll_records
  FOR SELECT TO public
  USING (tenant_id = get_user_tenant_id(auth.uid()) AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'nomina', 'ver')));

CREATE POLICY "Create payroll_records" ON public.payroll_records
  FOR INSERT TO public
  WITH CHECK (tenant_id = get_user_tenant_id(auth.uid()) AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'nomina', 'crear')));

CREATE POLICY "Update payroll_records" ON public.payroll_records
  FOR UPDATE TO public
  USING (tenant_id = get_user_tenant_id(auth.uid()) AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'nomina', 'editar')));

CREATE POLICY "Delete payroll_records" ON public.payroll_records
  FOR DELETE TO public
  USING (tenant_id = get_user_tenant_id(auth.uid()) AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'nomina', 'eliminar')));

-- Plantillas de certificación laboral
CREATE TABLE public.certificate_templates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id),
  name text NOT NULL,
  template_type text NOT NULL DEFAULT 'laboral',
  content_template text NOT NULL,
  active boolean DEFAULT true,
  created_by uuid,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

ALTER TABLE public.certificate_templates ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View certificate_templates" ON public.certificate_templates
  FOR SELECT TO public
  USING (tenant_id = get_user_tenant_id(auth.uid()) AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'nomina', 'ver')));

CREATE POLICY "Create certificate_templates" ON public.certificate_templates
  FOR INSERT TO public
  WITH CHECK (tenant_id = get_user_tenant_id(auth.uid()) AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'nomina', 'crear')));

CREATE POLICY "Update certificate_templates" ON public.certificate_templates
  FOR UPDATE TO public
  USING (tenant_id = get_user_tenant_id(auth.uid()) AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'nomina', 'editar')));

CREATE POLICY "Delete certificate_templates" ON public.certificate_templates
  FOR DELETE TO public
  USING (tenant_id = get_user_tenant_id(auth.uid()) AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'nomina', 'eliminar')));

-- ==============================
-- MÓDULO DE REGLAMENTO INTERNO
-- ==============================

-- Reglamentos con control de versiones
CREATE TABLE public.regulations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id),
  title text NOT NULL,
  version text NOT NULL DEFAULT '1.0',
  content_type text NOT NULL DEFAULT 'text',
  content_text text,
  document_url text,
  effective_date date NOT NULL DEFAULT CURRENT_DATE,
  status text NOT NULL DEFAULT 'borrador',
  requires_signature boolean DEFAULT true,
  published_at timestamptz,
  published_by uuid,
  created_by uuid,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

ALTER TABLE public.regulations ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View regulations" ON public.regulations
  FOR SELECT TO public
  USING (tenant_id = get_user_tenant_id(auth.uid()) AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'reglamento', 'ver')));

CREATE POLICY "Create regulations" ON public.regulations
  FOR INSERT TO public
  WITH CHECK (tenant_id = get_user_tenant_id(auth.uid()) AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'reglamento', 'crear')));

CREATE POLICY "Update regulations" ON public.regulations
  FOR UPDATE TO public
  USING (tenant_id = get_user_tenant_id(auth.uid()) AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'reglamento', 'editar')));

CREATE POLICY "Delete regulations" ON public.regulations
  FOR DELETE TO public
  USING (tenant_id = get_user_tenant_id(auth.uid()) AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'reglamento', 'eliminar')));

-- Acuses de recibo / firmas de lectura
CREATE TABLE public.regulation_acknowledgments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id),
  regulation_id uuid NOT NULL REFERENCES public.regulations(id) ON DELETE CASCADE,
  employee_id uuid NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
  acknowledged_at timestamptz,
  signature_url text,
  ip_address text,
  status text NOT NULL DEFAULT 'pendiente',
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  UNIQUE (regulation_id, employee_id)
);

ALTER TABLE public.regulation_acknowledgments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View regulation_acknowledgments" ON public.regulation_acknowledgments
  FOR SELECT TO public
  USING (tenant_id = get_user_tenant_id(auth.uid()) AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'reglamento', 'ver')));

CREATE POLICY "Create regulation_acknowledgments" ON public.regulation_acknowledgments
  FOR INSERT TO public
  WITH CHECK (tenant_id = get_user_tenant_id(auth.uid()) AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'reglamento', 'crear')));

CREATE POLICY "Update regulation_acknowledgments" ON public.regulation_acknowledgments
  FOR UPDATE TO public
  USING (tenant_id = get_user_tenant_id(auth.uid()) AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'reglamento', 'editar')));

-- Register modules for permissions
INSERT INTO public.modules (code, name, description, icon, active) VALUES
  ('nomina', 'Nómina', 'Gestión de contratos, nómina y certificaciones', 'Banknote', true),
  ('reglamento', 'Reglamento Interno', 'Control de versiones y socialización del reglamento', 'BookOpen', true)
ON CONFLICT (code) DO NOTHING;

-- Add permissions for both modules
INSERT INTO public.permissions (module_id, action, description)
SELECT m.id, a.action, a.description
FROM public.modules m
CROSS JOIN (VALUES
  ('ver'::permission_action, 'Ver registros'),
  ('crear'::permission_action, 'Crear registros'),
  ('editar'::permission_action, 'Editar registros'),
  ('eliminar'::permission_action, 'Eliminar registros')
) AS a(action, description)
WHERE m.code IN ('nomina', 'reglamento')
ON CONFLICT DO NOTHING;

-- Storage bucket for regulation documents
INSERT INTO storage.buckets (id, name, public) VALUES ('regulations', 'regulations', false)
ON CONFLICT DO NOTHING;

-- Storage RLS for regulations bucket
CREATE POLICY "Authenticated users can upload regulation docs"
ON storage.objects FOR INSERT TO authenticated
WITH CHECK (bucket_id = 'regulations');

CREATE POLICY "Users can view regulation docs in their tenant"
ON storage.objects FOR SELECT TO authenticated
USING (bucket_id = 'regulations');
