
-- Create signatures table
CREATE TABLE public.signatures (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  tenant_id UUID NOT NULL REFERENCES public.tenants(id),
  module TEXT NOT NULL, -- 'eventos', 'dotacion', 'evaluaciones_desempeno', etc.
  record_id UUID NOT NULL, -- ID of the source record
  employee_id UUID NOT NULL REFERENCES public.employees(id),
  signed_by UUID, -- auth user who performed the signature (null if employee self-signed)
  signature_url TEXT, -- URL in storage bucket
  signed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  watermark_text TEXT, -- "Firmado el 02/03/2026 10:30"
  method TEXT NOT NULL DEFAULT 'canvas' CHECK (method IN ('canvas', 'admin_confirmation')),
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Enable RLS
ALTER TABLE public.signatures ENABLE ROW LEVEL SECURITY;

-- RLS policies
CREATE POLICY "View signatures" ON public.signatures
  FOR SELECT USING (
    (tenant_id = get_user_tenant_id(auth.uid())) AND
    (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'firmas', 'ver'::permission_action))
  );

CREATE POLICY "Create signatures" ON public.signatures
  FOR INSERT WITH CHECK (
    (tenant_id = get_user_tenant_id(auth.uid())) AND
    (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'firmas', 'firmar'::permission_action))
  );

CREATE POLICY "Delete signatures" ON public.signatures
  FOR DELETE USING (
    (tenant_id = get_user_tenant_id(auth.uid())) AND
    (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'firmas', 'eliminar'::permission_action))
  );

-- Updated_at trigger
CREATE TRIGGER update_signatures_updated_at
  BEFORE UPDATE ON public.signatures
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Register firmas module and permissions
INSERT INTO public.modules (code, name, description, icon)
VALUES ('firmas', 'Firmas', 'Gestión centralizada de firmas digitales', 'PenTool');

INSERT INTO public.permissions (module_id, action, description)
SELECT m.id, a.action, a.description
FROM public.modules m,
(VALUES
  ('ver'::permission_action, 'Ver firmas'),
  ('firmar'::permission_action, 'Registrar firmas'),
  ('eliminar'::permission_action, 'Eliminar firmas')
) AS a(action, description)
WHERE m.code = 'firmas';

-- Grant all firmas permissions to existing system admin roles
INSERT INTO public.role_permissions (role_id, permission_id)
SELECT r.id, p.id
FROM public.roles r
CROSS JOIN public.permissions p
JOIN public.modules m ON p.module_id = m.id
WHERE r.is_system = true AND m.code = 'firmas'
ON CONFLICT DO NOTHING;

-- Create storage bucket for signatures
INSERT INTO storage.buckets (id, name, public) VALUES ('signatures', 'signatures', false);

-- Storage RLS: authenticated users can upload to their tenant folder
CREATE POLICY "Authenticated users can upload signatures"
  ON storage.objects FOR INSERT
  WITH CHECK (bucket_id = 'signatures' AND auth.role() = 'authenticated');

CREATE POLICY "Users can view signatures in their tenant"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'signatures' AND auth.role() = 'authenticated');
