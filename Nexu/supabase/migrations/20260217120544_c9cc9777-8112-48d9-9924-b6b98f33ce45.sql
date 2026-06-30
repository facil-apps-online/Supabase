
-- Create dotacion_types table following standard/custom pattern
CREATE TABLE public.dotacion_types (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  name TEXT NOT NULL,
  description TEXT,
  active BOOLEAN DEFAULT true,
  is_standard BOOLEAN DEFAULT false,
  tenant_id UUID REFERENCES public.tenants(id),
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Enable RLS
ALTER TABLE public.dotacion_types ENABLE ROW LEVEL SECURITY;

-- RLS policies (same pattern as exam_types, course_types, etc.)
CREATE POLICY "Everyone can view standard dotacion types"
  ON public.dotacion_types FOR SELECT
  USING (is_standard = true);

CREATE POLICY "Users can view tenant dotacion types"
  ON public.dotacion_types FOR SELECT
  USING (tenant_id = get_user_tenant_id(auth.uid()));

CREATE POLICY "Super admins can manage all dotacion types"
  ON public.dotacion_types FOR ALL
  USING (is_super_admin(auth.uid()));

CREATE POLICY "Users can create tenant dotacion types"
  ON public.dotacion_types FOR INSERT
  WITH CHECK (tenant_id = get_user_tenant_id(auth.uid()) AND is_standard = false);

CREATE POLICY "Users can update dotacion types"
  ON public.dotacion_types FOR UPDATE
  USING (
    (tenant_id = get_user_tenant_id(auth.uid()) AND is_standard = false)
    OR (is_standard = true AND get_user_tenant_id(auth.uid()) IS NOT NULL)
  );

CREATE POLICY "Users can delete tenant dotacion types"
  ON public.dotacion_types FOR DELETE
  USING (tenant_id = get_user_tenant_id(auth.uid()) AND is_standard = false);

-- Trigger for updated_at
CREATE TRIGGER update_dotacion_types_updated_at
  BEFORE UPDATE ON public.dotacion_types
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

-- Insert standard dotacion types
INSERT INTO public.dotacion_types (name, description, is_standard, tenant_id) VALUES
  ('Uniforme', 'Prendas de vestir corporativas', true, NULL),
  ('EPP', 'Elementos de protección personal', true, NULL),
  ('Herramienta', 'Herramientas de trabajo', true, NULL),
  ('Calzado', 'Calzado de seguridad o corporativo', true, NULL),
  ('Accesorio', 'Accesorios y complementos', true, NULL);
