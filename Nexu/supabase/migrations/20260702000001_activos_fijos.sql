
-- Master: tipos de activo fijo
CREATE TABLE public.activo_fijo_tipos (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid REFERENCES public.tenants(id) ON DELETE CASCADE,
  name text NOT NULL,
  description text,
  is_standard boolean NOT NULL DEFAULT false,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.activo_fijo_tipos TO authenticated;
GRANT ALL ON public.activo_fijo_tipos TO service_role;
ALTER TABLE public.activo_fijo_tipos ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View standard or own tenant activo fijo tipos" ON public.activo_fijo_tipos
  FOR SELECT TO authenticated
  USING (is_standard = true OR tenant_id = public.get_user_tenant_id(auth.uid()));
CREATE POLICY "Manage own tenant activo fijo tipos" ON public.activo_fijo_tipos
  FOR ALL TO authenticated
  USING (tenant_id = public.get_user_tenant_id(auth.uid()) AND is_standard = false)
  WITH CHECK (tenant_id = public.get_user_tenant_id(auth.uid()) AND is_standard = false);

CREATE TRIGGER trg_activo_fijo_tipos_updated BEFORE UPDATE ON public.activo_fijo_tipos
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- Seed standard tipos
INSERT INTO public.activo_fijo_tipos (name, description, is_standard, active) VALUES
  ('Computador', 'Equipos de cómputo de escritorio y portátiles', true, true),
  ('Celular', 'Teléfonos móviles y smartphones', true, true),
  ('Tablet', 'Tabletas digitales', true, true),
  ('Monitor', 'Monitores y pantallas', true, true),
  ('Impresora', 'Impresoras y multifuncionales', true, true),
  ('Otro', 'Otros activos fijos no categorizados', true, true);

-- Master: estados de activo fijo
CREATE TABLE public.activo_fijo_estados (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid REFERENCES public.tenants(id) ON DELETE CASCADE,
  name text NOT NULL,
  description text,
  is_standard boolean NOT NULL DEFAULT false,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.activo_fijo_estados TO authenticated;
GRANT ALL ON public.activo_fijo_estados TO service_role;
ALTER TABLE public.activo_fijo_estados ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View standard or own tenant activo fijo estados" ON public.activo_fijo_estados
  FOR SELECT TO authenticated
  USING (is_standard = true OR tenant_id = public.get_user_tenant_id(auth.uid()));
CREATE POLICY "Manage own tenant activo fijo estados" ON public.activo_fijo_estados
  FOR ALL TO authenticated
  USING (tenant_id = public.get_user_tenant_id(auth.uid()) AND is_standard = false)
  WITH CHECK (tenant_id = public.get_user_tenant_id(auth.uid()) AND is_standard = false);

CREATE TRIGGER trg_activo_fijo_estados_updated BEFORE UPDATE ON public.activo_fijo_estados
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- Seed standard estados
INSERT INTO public.activo_fijo_estados (name, description, is_standard, active) VALUES
  ('Disponible', 'Activo sin asignar, listo para uso', true, true),
  ('Asignado', 'Activo asignado a un empleado', true, true),
  ('En reparación', 'Activo en proceso de reparación o mantenimiento', true, true),
  ('Dado de baja', 'Activo retirado del inventario', true, true);

-- Master: marcas de activo fijo
CREATE TABLE public.activo_fijo_marcas (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid REFERENCES public.tenants(id) ON DELETE CASCADE,
  name text NOT NULL,
  is_standard boolean NOT NULL DEFAULT false,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.activo_fijo_marcas TO authenticated;
GRANT ALL ON public.activo_fijo_marcas TO service_role;
ALTER TABLE public.activo_fijo_marcas ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View standard or own tenant activo fijo marcas" ON public.activo_fijo_marcas
  FOR SELECT TO authenticated
  USING (is_standard = true OR tenant_id = public.get_user_tenant_id(auth.uid()));
CREATE POLICY "Manage own tenant activo fijo marcas" ON public.activo_fijo_marcas
  FOR ALL TO authenticated
  USING (tenant_id = public.get_user_tenant_id(auth.uid()) AND is_standard = false)
  WITH CHECK (tenant_id = public.get_user_tenant_id(auth.uid()) AND is_standard = false);

CREATE TRIGGER trg_activo_fijo_marcas_updated BEFORE UPDATE ON public.activo_fijo_marcas
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- Main table
CREATE TABLE public.activos_fijos (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  tipo_id uuid NOT NULL REFERENCES public.activo_fijo_tipos(id),
  marca_id uuid NOT NULL REFERENCES public.activo_fijo_marcas(id),
  modelo text NOT NULL,
  numero_serie text,
  estado_id uuid NOT NULL REFERENCES public.activo_fijo_estados(id),
  empleado_asignado_id uuid REFERENCES public.employees(id) ON DELETE SET NULL,
  fecha_asignacion timestamptz,
  fecha_compra date,
  valor numeric(12,2),
  notas text,
  created_by uuid,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.activos_fijos TO authenticated;
GRANT ALL ON public.activos_fijos TO service_role;
ALTER TABLE public.activos_fijos ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Tenant admins view activos fijos" ON public.activos_fijos
  FOR SELECT TO authenticated
  USING (tenant_id = public.get_user_tenant_id(auth.uid()));
CREATE POLICY "Tenant admins insert activos fijos" ON public.activos_fijos
  FOR INSERT TO authenticated
  WITH CHECK (tenant_id = public.get_user_tenant_id(auth.uid()));
CREATE POLICY "Tenant admins update activos fijos" ON public.activos_fijos
  FOR UPDATE TO authenticated
  USING (tenant_id = public.get_user_tenant_id(auth.uid()));
CREATE POLICY "Tenant admins delete activos fijos" ON public.activos_fijos
  FOR DELETE TO authenticated
  USING (tenant_id = public.get_user_tenant_id(auth.uid()));

CREATE TRIGGER trg_activos_fijos_updated BEFORE UPDATE ON public.activos_fijos
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE INDEX idx_activos_fijos_tenant ON public.activos_fijos(tenant_id);
CREATE INDEX idx_activos_fijos_empleado ON public.activos_fijos(empleado_asignado_id);
CREATE INDEX idx_activos_fijos_estado ON public.activos_fijos(estado_id);
CREATE INDEX idx_activos_fijos_tipo ON public.activos_fijos(tipo_id);

-- History table
CREATE TABLE public.activos_fijos_historial (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  activo_fijo_id uuid NOT NULL REFERENCES public.activos_fijos(id) ON DELETE CASCADE,
  empleado_id uuid REFERENCES public.employees(id) ON DELETE SET NULL,
  tipo_evento public.activo_historial_evento NOT NULL,
  fecha_evento timestamptz NOT NULL DEFAULT now(),
  descripcion text,
  created_at timestamptz DEFAULT now()
);
GRANT SELECT, INSERT ON public.activos_fijos_historial TO authenticated;
GRANT ALL ON public.activos_fijos_historial TO service_role;
ALTER TABLE public.activos_fijos_historial ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Tenant admins view historial" ON public.activos_fijos_historial
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.activos_fijos af
    WHERE af.id = activo_fijo_id
      AND af.tenant_id = public.get_user_tenant_id(auth.uid())
  ));
CREATE POLICY "Tenant admins insert historial" ON public.activos_fijos_historial
  FOR INSERT TO authenticated
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.activos_fijos af
    WHERE af.id = activo_fijo_id
      AND af.tenant_id = public.get_user_tenant_id(auth.uid())
  ));

CREATE INDEX idx_historial_activo ON public.activos_fijos_historial(activo_fijo_id);
CREATE INDEX idx_historial_empleado ON public.activos_fijos_historial(empleado_id);
