
-- Create course_providers table following the standard/custom pattern
CREATE TABLE public.course_providers (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  name TEXT NOT NULL,
  description TEXT,
  active BOOLEAN DEFAULT true,
  is_standard BOOLEAN DEFAULT false,
  tenant_id UUID REFERENCES public.tenants(id),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Enable RLS
ALTER TABLE public.course_providers ENABLE ROW LEVEL SECURITY;

-- RLS policies following the standard/custom pattern (same as exam_types, vigilancia_types)
CREATE POLICY "Everyone can view standard course providers"
ON public.course_providers FOR SELECT
USING (is_standard = true);

CREATE POLICY "Users can view tenant course providers"
ON public.course_providers FOR SELECT
USING (tenant_id = get_user_tenant_id(auth.uid()));

CREATE POLICY "Users can create tenant course providers"
ON public.course_providers FOR INSERT
WITH CHECK (tenant_id = get_user_tenant_id(auth.uid()) AND is_standard = false);

CREATE POLICY "Users can update tenant course providers"
ON public.course_providers FOR UPDATE
USING (tenant_id = get_user_tenant_id(auth.uid()) AND is_standard = false);

CREATE POLICY "Users can delete tenant course providers"
ON public.course_providers FOR DELETE
USING (tenant_id = get_user_tenant_id(auth.uid()) AND is_standard = false);

CREATE POLICY "Super admins can manage all course providers"
ON public.course_providers FOR ALL
USING (is_super_admin(auth.uid()));

-- Trigger for updated_at
CREATE TRIGGER update_course_providers_updated_at
BEFORE UPDATE ON public.course_providers
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();

-- Insert some standard providers
INSERT INTO public.course_providers (name, description, is_standard, active) VALUES
('SENA', 'Servicio Nacional de Aprendizaje', true, true),
('Cruz Roja', 'Cruz Roja Colombiana', true, true),
('ARL', 'Administradora de Riesgos Laborales', true, true),
('Defensa Civil', 'Defensa Civil Colombiana', true, true);
