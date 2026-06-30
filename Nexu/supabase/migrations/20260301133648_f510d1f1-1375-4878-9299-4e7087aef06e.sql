
-- 1. Create event_status enum
CREATE TYPE public.event_status AS ENUM ('borrador', 'en_progreso', 'completado', 'cancelado');

-- 2. Create event_types table (standard/custom pattern)
CREATE TABLE public.event_types (
  id uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  name text NOT NULL,
  description text,
  active boolean DEFAULT true,
  is_standard boolean DEFAULT false,
  tenant_id uuid REFERENCES public.tenants(id),
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

ALTER TABLE public.event_types ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Everyone can view standard event types" ON public.event_types FOR SELECT USING (is_standard = true);
CREATE POLICY "Users can view tenant event types" ON public.event_types FOR SELECT USING (tenant_id = get_user_tenant_id(auth.uid()));
CREATE POLICY "Super admins can manage all event types" ON public.event_types FOR ALL USING (is_super_admin(auth.uid()));
CREATE POLICY "Users can create tenant event types" ON public.event_types FOR INSERT WITH CHECK (tenant_id = get_user_tenant_id(auth.uid()) AND is_standard = false);
CREATE POLICY "Users can update event types" ON public.event_types FOR UPDATE USING ((tenant_id = get_user_tenant_id(auth.uid()) AND is_standard = false) OR (is_standard = true AND get_user_tenant_id(auth.uid()) IS NOT NULL));
CREATE POLICY "Users can delete tenant event types" ON public.event_types FOR DELETE USING (tenant_id = get_user_tenant_id(auth.uid()) AND is_standard = false);

-- Seed standard event types
INSERT INTO public.event_types (name, description, is_standard, tenant_id) VALUES
  ('Inducción', 'Evento de inducción para nuevos empleados', true, NULL),
  ('Reinducción', 'Evento de reinducción periódica', true, NULL),
  ('Capacitación', 'Evento de capacitación o formación', true, NULL),
  ('Reunión', 'Reunión de equipo o comité', true, NULL),
  ('Simulacro', 'Simulacro de emergencia', true, NULL);

-- 3. Create events table
CREATE TABLE public.events (
  id uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  tenant_id uuid NOT NULL REFERENCES public.tenants(id),
  title text NOT NULL,
  event_type text NOT NULL,
  event_date date NOT NULL,
  description text,
  location text,
  status event_status DEFAULT 'borrador',
  created_by uuid,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

ALTER TABLE public.events ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View events" ON public.events FOR SELECT USING (tenant_id = get_user_tenant_id(auth.uid()) AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'eventos', 'ver')));
CREATE POLICY "Create events" ON public.events FOR INSERT WITH CHECK (tenant_id = get_user_tenant_id(auth.uid()) AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'eventos', 'crear')));
CREATE POLICY "Update events" ON public.events FOR UPDATE USING (tenant_id = get_user_tenant_id(auth.uid()) AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'eventos', 'editar')));
CREATE POLICY "Delete events" ON public.events FOR DELETE USING (tenant_id = get_user_tenant_id(auth.uid()) AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'eventos', 'eliminar')));

CREATE TRIGGER update_events_updated_at BEFORE UPDATE ON public.events FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- 4. Create event_participants table
CREATE TABLE public.event_participants (
  id uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  event_id uuid NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
  employee_id uuid NOT NULL REFERENCES public.employees(id),
  signed boolean DEFAULT false,
  signature_url text,
  signed_at timestamptz,
  invited_at timestamptz DEFAULT now()
);

ALTER TABLE public.event_participants ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Tenant isolation for event_participants" ON public.event_participants FOR ALL USING (
  EXISTS (
    SELECT 1 FROM events e
    WHERE e.id = event_participants.event_id
    AND (e.tenant_id = get_user_tenant_id(auth.uid()) OR is_super_admin(auth.uid()))
  )
);

-- 5. Add 'eventos' module for permissions
INSERT INTO public.modules (code, name, description, icon) VALUES
  ('eventos', 'Eventos y Firmas', 'Gestión de eventos con recolección de firmas', 'CalendarCheck');

-- 6. Add permissions for the eventos module
INSERT INTO public.permissions (module_id, action, description)
SELECT m.id, a.action, 'Permiso de ' || a.action || ' en eventos'
FROM public.modules m
CROSS JOIN (VALUES ('ver'::permission_action), ('crear'::permission_action), ('editar'::permission_action), ('eliminar'::permission_action), ('firmar'::permission_action)) AS a(action)
WHERE m.code = 'eventos';
