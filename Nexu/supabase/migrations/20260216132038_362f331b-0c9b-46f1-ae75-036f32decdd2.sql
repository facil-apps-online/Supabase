
-- Create course_types table following the standard/custom pattern
CREATE TABLE public.course_types (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  name TEXT NOT NULL,
  description TEXT,
  active BOOLEAN DEFAULT true,
  is_standard BOOLEAN DEFAULT false,
  tenant_id UUID REFERENCES public.tenants(id),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

ALTER TABLE public.course_types ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Everyone can view standard course types"
ON public.course_types FOR SELECT USING (is_standard = true);

CREATE POLICY "Users can view tenant course types"
ON public.course_types FOR SELECT USING (tenant_id = get_user_tenant_id(auth.uid()));

CREATE POLICY "Users can create tenant course types"
ON public.course_types FOR INSERT WITH CHECK (tenant_id = get_user_tenant_id(auth.uid()) AND is_standard = false);

CREATE POLICY "Users can update tenant course types"
ON public.course_types FOR UPDATE USING (tenant_id = get_user_tenant_id(auth.uid()) AND is_standard = false);

CREATE POLICY "Users can delete tenant course types"
ON public.course_types FOR DELETE USING (tenant_id = get_user_tenant_id(auth.uid()) AND is_standard = false);

CREATE POLICY "Super admins can manage all course types"
ON public.course_types FOR ALL USING (is_super_admin(auth.uid()));

CREATE TRIGGER update_course_types_updated_at
BEFORE UPDATE ON public.course_types
FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

INSERT INTO public.course_types (name, description, is_standard, active) VALUES
('Trabajo en Alturas', 'Certificación para trabajo seguro en alturas', true, true),
('Primeros Auxilios', 'Curso básico de primeros auxilios', true, true),
('Manejo de Extintores', 'Capacitación en uso de extintores', true, true),
('Manipulación de Alimentos', 'Certificación en manipulación higiénica de alimentos', true, true),
('Espacios Confinados', 'Seguridad en espacios confinados', true, true),
('Manejo Defensivo', 'Conducción y manejo defensivo', true, true),
('Brigadas de Emergencia', 'Formación para brigadas de emergencia', true, true);
