
-- Fix constraints for foreign keys referencing tenants(id)
ALTER TABLE public.tenants ADD CONSTRAINT tenants_id_key UNIQUE (id);

-- Enums
CREATE TYPE public.incapacidad_estado AS ENUM ('registrada','en_revision','aprobada','rechazada','transcrita_nomina');
CREATE TYPE public.incapacidad_origen AS ENUM ('admin','portal_empleado');

-- Master types
CREATE TABLE public.incapacidad_types (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid REFERENCES public.tenants(id) ON DELETE CASCADE,
  code text NOT NULL,
  name text NOT NULL,
  description text,
  is_standard boolean NOT NULL DEFAULT false,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.incapacidad_types TO authenticated;
GRANT ALL ON public.incapacidad_types TO service_role;
ALTER TABLE public.incapacidad_types ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View standard or own tenant incapacidad types" ON public.incapacidad_types
  FOR SELECT TO authenticated
  USING (is_standard = true OR tenant_id = public.get_user_tenant_id(auth.uid()));
CREATE POLICY "Manage own tenant incapacidad types" ON public.incapacidad_types
  FOR ALL TO authenticated
  USING (tenant_id = public.get_user_tenant_id(auth.uid()) AND is_standard = false)
  WITH CHECK (tenant_id = public.get_user_tenant_id(auth.uid()) AND is_standard = false);

CREATE TRIGGER trg_incapacidad_types_updated BEFORE UPDATE ON public.incapacidad_types
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- Main table
CREATE TABLE public.incapacidades (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  employee_id uuid NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
  tipo text NOT NULL,
  fecha_inicio date NOT NULL,
  fecha_fin date NOT NULL,
  dias integer NOT NULL,
  diagnostico text,
  codigo_cie text,
  entidad text,
  numero_radicado text,
  prorroga_de uuid REFERENCES public.incapacidades(id) ON DELETE SET NULL,
  estado public.incapacidad_estado NOT NULL DEFAULT 'registrada',
  origen public.incapacidad_origen NOT NULL DEFAULT 'admin',
  documento_url text,
  notas_internas text,
  created_by uuid,
  reviewed_by uuid,
  reviewed_at timestamptz,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.incapacidades TO authenticated;
GRANT ALL ON public.incapacidades TO service_role;
ALTER TABLE public.incapacidades ENABLE ROW LEVEL SECURITY;

-- Admin policies (tenant scope)
CREATE POLICY "Tenant admins view incapacidades" ON public.incapacidades
  FOR SELECT TO authenticated
  USING (tenant_id = public.get_user_tenant_id(auth.uid()));
CREATE POLICY "Tenant admins insert incapacidades" ON public.incapacidades
  FOR INSERT TO authenticated
  WITH CHECK (tenant_id = public.get_user_tenant_id(auth.uid()));
CREATE POLICY "Tenant admins update incapacidades" ON public.incapacidades
  FOR UPDATE TO authenticated
  USING (tenant_id = public.get_user_tenant_id(auth.uid()));
CREATE POLICY "Tenant admins delete incapacidades" ON public.incapacidades
  FOR DELETE TO authenticated
  USING (tenant_id = public.get_user_tenant_id(auth.uid()));

-- Employee portal: SELECT own + INSERT own (read-only afterwards)
CREATE POLICY "Portal employee views own incapacidades" ON public.incapacidades
  FOR SELECT TO authenticated
  USING (employee_id = public.get_current_employee_id());
CREATE POLICY "Portal employee creates own incapacidad" ON public.incapacidades
  FOR INSERT TO authenticated
  WITH CHECK (
    employee_id = public.get_current_employee_id()
    AND origen = 'portal_empleado'
    AND estado = 'registrada'
  );

CREATE TRIGGER trg_incapacidades_updated BEFORE UPDATE ON public.incapacidades
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE INDEX idx_incapacidades_tenant ON public.incapacidades(tenant_id);
CREATE INDEX idx_incapacidades_employee ON public.incapacidades(employee_id);
CREATE INDEX idx_incapacidades_estado ON public.incapacidades(estado);

-- notifications.employee_id (optional, portal scope)
ALTER TABLE public.notifications ADD COLUMN IF NOT EXISTS employee_id uuid REFERENCES public.employees(id) ON DELETE CASCADE;
ALTER TABLE public.notifications ALTER COLUMN user_id DROP NOT NULL;
CREATE INDEX IF NOT EXISTS idx_notifications_employee ON public.notifications(employee_id);

CREATE POLICY "Portal employee views own notifications" ON public.notifications
  FOR SELECT TO authenticated
  USING (employee_id IS NOT NULL AND employee_id = public.get_current_employee_id());
CREATE POLICY "Portal employee updates own notifications" ON public.notifications
  FOR UPDATE TO authenticated
  USING (employee_id IS NOT NULL AND employee_id = public.get_current_employee_id());

-- evidences.uploaded_by_employee_id
ALTER TABLE public.evidences ADD COLUMN IF NOT EXISTS uploaded_by_employee_id uuid REFERENCES public.employees(id) ON DELETE SET NULL;

CREATE POLICY "Portal employee views own evidences" ON public.evidences
  FOR SELECT TO authenticated
  USING (employee_id = public.get_current_employee_id());
CREATE POLICY "Portal employee inserts own evidences" ON public.evidences
  FOR INSERT TO authenticated
  WITH CHECK (
    employee_id = public.get_current_employee_id()
    AND uploaded_by_employee_id = public.get_current_employee_id()
    AND tenant_id = (SELECT tenant_id FROM public.employees WHERE id = public.get_current_employee_id())
  );

-- employee_activity_log
CREATE TABLE public.employee_activity_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  employee_id uuid NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
  action text NOT NULL,
  entity_type text,
  entity_id uuid,
  metadata jsonb DEFAULT '{}'::jsonb,
  ip_address text,
  user_agent text,
  created_at timestamptz DEFAULT now()
);
GRANT SELECT, INSERT ON public.employee_activity_log TO authenticated;
GRANT ALL ON public.employee_activity_log TO service_role;
ALTER TABLE public.employee_activity_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Tenant admins view activity log" ON public.employee_activity_log
  FOR SELECT TO authenticated
  USING (tenant_id = public.get_user_tenant_id(auth.uid()));
CREATE POLICY "Portal employee views own activity" ON public.employee_activity_log
  FOR SELECT TO authenticated
  USING (employee_id = public.get_current_employee_id());
CREATE POLICY "Portal employee inserts own activity" ON public.employee_activity_log
  FOR INSERT TO authenticated
  WITH CHECK (employee_id = public.get_current_employee_id());

CREATE INDEX idx_activity_log_employee ON public.employee_activity_log(employee_id, created_at DESC);
CREATE INDEX idx_activity_log_tenant ON public.employee_activity_log(tenant_id);

-- Storage policies for 'incapacidades' bucket (employee + admin)
CREATE POLICY "Portal employee uploads own incapacidad docs" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'incapacidades'
    AND (storage.foldername(name))[1] = public.get_current_employee_id()::text
  );
CREATE POLICY "Portal employee reads own incapacidad docs" ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'incapacidades'
    AND (
      (storage.foldername(name))[1] = public.get_current_employee_id()::text
      OR EXISTS (
        SELECT 1 FROM public.incapacidades i
        WHERE i.documento_url = storage.objects.name
          AND i.tenant_id = public.get_user_tenant_id(auth.uid())
      )
    )
  );
CREATE POLICY "Tenant admins manage incapacidad docs" ON storage.objects
  FOR ALL TO authenticated
  USING (
    bucket_id = 'incapacidades'
    AND EXISTS (
      SELECT 1 FROM public.employees e
      WHERE e.id::text = (storage.foldername(storage.objects.name))[1]
        AND e.tenant_id = public.get_user_tenant_id(auth.uid())
    )
  )
  WITH CHECK (
    bucket_id = 'incapacidades'
    AND EXISTS (
      SELECT 1 FROM public.employees e
      WHERE e.id::text = (storage.foldername(storage.objects.name))[1]
        AND e.tenant_id = public.get_user_tenant_id(auth.uid())
    )
  );
