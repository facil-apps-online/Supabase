
-- Create committee_roles table following the standard/custom pattern
CREATE TABLE public.committee_roles (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  name TEXT NOT NULL,
  description TEXT,
  is_standard BOOLEAN DEFAULT false,
  tenant_id UUID REFERENCES public.tenants(id),
  active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Enable RLS
ALTER TABLE public.committee_roles ENABLE ROW LEVEL SECURITY;

-- RLS policies (same pattern as other master data)
CREATE POLICY "Everyone can view standard committee roles"
  ON public.committee_roles FOR SELECT
  USING (is_standard = true);

CREATE POLICY "Users can view tenant committee roles"
  ON public.committee_roles FOR SELECT
  USING (tenant_id = get_user_tenant_id(auth.uid()));

CREATE POLICY "Super admins can manage all committee roles"
  ON public.committee_roles FOR ALL
  USING (is_super_admin(auth.uid()));

CREATE POLICY "Users can create tenant committee roles"
  ON public.committee_roles FOR INSERT
  WITH CHECK (tenant_id = get_user_tenant_id(auth.uid()) AND is_standard = false);

CREATE POLICY "Users can update committee roles"
  ON public.committee_roles FOR UPDATE
  USING (
    (tenant_id = get_user_tenant_id(auth.uid()) AND is_standard = false)
    OR (is_standard = true AND get_user_tenant_id(auth.uid()) IS NOT NULL)
  );

CREATE POLICY "Users can delete tenant committee roles"
  ON public.committee_roles FOR DELETE
  USING (tenant_id = get_user_tenant_id(auth.uid()) AND is_standard = false);

-- Seed standard roles
INSERT INTO public.committee_roles (name, is_standard, tenant_id) VALUES
  ('Presidente', true, NULL),
  ('Secretario', true, NULL),
  ('Coordinador', true, NULL),
  ('Miembro', true, NULL),
  ('Suplente', true, NULL);

-- Trigger for updated_at
CREATE TRIGGER update_committee_roles_updated_at
  BEFORE UPDATE ON public.committee_roles
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();
