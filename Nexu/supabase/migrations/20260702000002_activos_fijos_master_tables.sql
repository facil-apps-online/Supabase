
-- 1. Master tables (same as 001 but idempotent)
CREATE TABLE IF NOT EXISTS public.activo_fijo_tipos (
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

DROP POLICY IF EXISTS "View standard or own tenant activo fijo tipos" ON public.activo_fijo_tipos;
CREATE POLICY "View standard or own tenant activo fijo tipos" ON public.activo_fijo_tipos
  FOR SELECT TO authenticated
  USING (is_standard = true OR tenant_id = public.get_user_tenant_id(auth.uid()));
DROP POLICY IF EXISTS "Manage own tenant activo fijo tipos" ON public.activo_fijo_tipos;
CREATE POLICY "Manage own tenant activo fijo tipos" ON public.activo_fijo_tipos
  FOR ALL TO authenticated
  USING (tenant_id = public.get_user_tenant_id(auth.uid()) AND is_standard = false)
  WITH CHECK (tenant_id = public.get_user_tenant_id(auth.uid()) AND is_standard = false);

DROP TRIGGER IF EXISTS trg_activo_fijo_tipos_updated ON public.activo_fijo_tipos;
CREATE TRIGGER trg_activo_fijo_tipos_updated BEFORE UPDATE ON public.activo_fijo_tipos
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- Seed standard tipos (idempotent)
INSERT INTO public.activo_fijo_tipos (name, description, is_standard, active)
SELECT * FROM (VALUES
  ('Computador', 'Equipos de cómputo de escritorio y portátiles', true, true),
  ('Celular', 'Teléfonos móviles y smartphones', true, true),
  ('Tablet', 'Tabletas digitales', true, true),
  ('Monitor', 'Monitores y pantallas', true, true),
  ('Impresora', 'Impresoras y multifuncionales', true, true),
  ('Otro', 'Otros activos fijos no categorizados', true, true)
) AS v(name, description, is_standard, active)
WHERE NOT EXISTS (SELECT 1 FROM public.activo_fijo_tipos WHERE is_standard = true);

CREATE TABLE IF NOT EXISTS public.activo_fijo_estados (
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

DROP POLICY IF EXISTS "View standard or own tenant activo fijo estados" ON public.activo_fijo_estados;
CREATE POLICY "View standard or own tenant activo fijo estados" ON public.activo_fijo_estados
  FOR SELECT TO authenticated
  USING (is_standard = true OR tenant_id = public.get_user_tenant_id(auth.uid()));
DROP POLICY IF EXISTS "Manage own tenant activo fijo estados" ON public.activo_fijo_estados;
CREATE POLICY "Manage own tenant activo fijo estados" ON public.activo_fijo_estados
  FOR ALL TO authenticated
  USING (tenant_id = public.get_user_tenant_id(auth.uid()) AND is_standard = false)
  WITH CHECK (tenant_id = public.get_user_tenant_id(auth.uid()) AND is_standard = false);

DROP TRIGGER IF EXISTS trg_activo_fijo_estados_updated ON public.activo_fijo_estados;
CREATE TRIGGER trg_activo_fijo_estados_updated BEFORE UPDATE ON public.activo_fijo_estados
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

INSERT INTO public.activo_fijo_estados (name, description, is_standard, active)
SELECT * FROM (VALUES
  ('Disponible', 'Activo sin asignar, listo para uso', true, true),
  ('Asignado', 'Activo asignado a un empleado', true, true),
  ('En reparación', 'Activo en proceso de reparación o mantenimiento', true, true),
  ('Dado de baja', 'Activo retirado del inventario', true, true)
) AS v(name, description, is_standard, active)
WHERE NOT EXISTS (SELECT 1 FROM public.activo_fijo_estados WHERE is_standard = true);

CREATE TABLE IF NOT EXISTS public.activo_fijo_marcas (
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

DROP POLICY IF EXISTS "View standard or own tenant activo fijo marcas" ON public.activo_fijo_marcas;
CREATE POLICY "View standard or own tenant activo fijo marcas" ON public.activo_fijo_marcas
  FOR SELECT TO authenticated
  USING (is_standard = true OR tenant_id = public.get_user_tenant_id(auth.uid()));
DROP POLICY IF EXISTS "Manage own tenant activo fijo marcas" ON public.activo_fijo_marcas;
CREATE POLICY "Manage own tenant activo fijo marcas" ON public.activo_fijo_marcas
  FOR ALL TO authenticated
  USING (tenant_id = public.get_user_tenant_id(auth.uid()) AND is_standard = false)
  WITH CHECK (tenant_id = public.get_user_tenant_id(auth.uid()) AND is_standard = false);

DROP TRIGGER IF EXISTS trg_activo_fijo_marcas_updated ON public.activo_fijo_marcas;
CREATE TRIGGER trg_activo_fijo_marcas_updated BEFORE UPDATE ON public.activo_fijo_marcas
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- 2. Migrate activos_fijos: add FK columns, map data, drop old columns

-- Add new columns (nullable initially)
ALTER TABLE public.activos_fijos ADD COLUMN IF NOT EXISTS tipo_id uuid REFERENCES public.activo_fijo_tipos(id);
ALTER TABLE public.activos_fijos ADD COLUMN IF NOT EXISTS estado_id uuid REFERENCES public.activo_fijo_estados(id);
ALTER TABLE public.activos_fijos ADD COLUMN IF NOT EXISTS marca_id uuid REFERENCES public.activo_fijo_marcas(id);

-- Map enum values to master table IDs using a case-insensitive match on the first word
UPDATE public.activos_fijos af
SET tipo_id = aft.id
FROM public.activo_fijo_tipos aft
WHERE af.tipo_id IS NULL
  AND LOWER(aft.name) = LOWER(af.tipo::text);

UPDATE public.activos_fijos af
SET estado_id = afe.id
FROM public.activo_fijo_estados afe
WHERE af.estado_id IS NULL
  AND (
    LOWER(afe.name) = LOWER(af.estado::text)
    OR (LOWER(afe.name) = 'en reparación' AND LOWER(af.estado::text) = 'en_reparacion')
  );

-- For marca, promote existing text values into the master table per tenant
INSERT INTO public.activo_fijo_marcas (name, tenant_id, is_standard, active)
SELECT DISTINCT af.marca, af.tenant_id, false, true
FROM public.activos_fijos af
WHERE af.marca IS NOT NULL AND af.marca != ''
  AND NOT EXISTS (
    SELECT 1 FROM public.activo_fijo_marcas afm
    WHERE afm.name = af.marca AND afm.tenant_id = af.tenant_id
  );

UPDATE public.activos_fijos af
SET marca_id = afm.id
FROM public.activo_fijo_marcas afm
WHERE af.marca_id IS NULL
  AND af.marca IS NOT NULL AND af.marca != ''
  AND afm.name = af.marca
  AND afm.tenant_id = af.tenant_id;

-- For rows that still have NULL (shouldn't happen), assign a fallback
UPDATE public.activos_fijos SET tipo_id = (SELECT id FROM public.activo_fijo_tipos WHERE name = 'Otro' LIMIT 1) WHERE tipo_id IS NULL;
UPDATE public.activos_fijos SET estado_id = (SELECT id FROM public.activo_fijo_estados WHERE name = 'Disponible' LIMIT 1) WHERE estado_id IS NULL;

-- Now make them NOT NULL
ALTER TABLE public.activos_fijos ALTER COLUMN tipo_id SET NOT NULL;
ALTER TABLE public.activos_fijos ALTER COLUMN estado_id SET NOT NULL;

-- Drop old columns
ALTER TABLE public.activos_fijos DROP COLUMN IF EXISTS tipo;
ALTER TABLE public.activos_fijos DROP COLUMN IF EXISTS estado;
ALTER TABLE public.activos_fijos DROP COLUMN IF EXISTS marca;

-- Drop old enum types (only if they exist and nothing else depends on them)
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_type WHERE typname = 'activo_fijo_tipo') THEN
    DROP TYPE public.activo_fijo_tipo;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_type WHERE typname = 'activo_fijo_estado') THEN
    DROP TYPE public.activo_fijo_estado;
  END IF;
END $$;

-- Update indexes
DROP INDEX IF EXISTS idx_activos_fijos_estado;
CREATE INDEX IF NOT EXISTS idx_activos_fijos_estado_id ON public.activos_fijos(estado_id);
CREATE INDEX IF NOT EXISTS idx_activos_fijos_tipo_id ON public.activos_fijos(tipo_id);

-- 3. Update RLS policies on activos_fijos (re-create to ensure they cover new schema)
DROP POLICY IF EXISTS "Tenant admins view activos fijos" ON public.activos_fijos;
DROP POLICY IF EXISTS "Tenant admins insert activos fijos" ON public.activos_fijos;
DROP POLICY IF EXISTS "Tenant admins update activos fijos" ON public.activos_fijos;
DROP POLICY IF EXISTS "Tenant admins delete activos fijos" ON public.activos_fijos;

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
