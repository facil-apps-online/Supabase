
-- Add is_standard column to vigilancia_types
ALTER TABLE public.vigilancia_types ADD COLUMN is_standard boolean DEFAULT false;

-- Make tenant_id nullable for standard types
ALTER TABLE public.vigilancia_types ALTER COLUMN tenant_id DROP NOT NULL;

-- Drop existing RLS policies
DROP POLICY IF EXISTS "Users can view vigilancia types from their tenant" ON public.vigilancia_types;
DROP POLICY IF EXISTS "Users can create vigilancia types in their tenant" ON public.vigilancia_types;
DROP POLICY IF EXISTS "Users can update vigilancia types in their tenant" ON public.vigilancia_types;
DROP POLICY IF EXISTS "Users can delete vigilancia types in their tenant" ON public.vigilancia_types;

-- New RLS policies
CREATE POLICY "Everyone can view standard vigilancia types"
ON public.vigilancia_types FOR SELECT
USING (is_standard = true);

CREATE POLICY "Users can view tenant vigilancia types"
ON public.vigilancia_types FOR SELECT
USING (tenant_id = get_user_tenant_id(auth.uid()));

CREATE POLICY "Super admins can manage all vigilancia types"
ON public.vigilancia_types FOR ALL
USING (is_super_admin(auth.uid()));

CREATE POLICY "Users can create tenant vigilancia types"
ON public.vigilancia_types FOR INSERT
WITH CHECK (tenant_id = get_user_tenant_id(auth.uid()) AND is_standard = false);

CREATE POLICY "Users can update tenant vigilancia types"
ON public.vigilancia_types FOR UPDATE
USING (tenant_id = get_user_tenant_id(auth.uid()) AND is_standard = false);

CREATE POLICY "Users can delete tenant vigilancia types"
ON public.vigilancia_types FOR DELETE
USING (tenant_id = get_user_tenant_id(auth.uid()) AND is_standard = false);

-- Insert standard vigilancia types
INSERT INTO public.vigilancia_types (name, description, is_standard, active, tenant_id) VALUES
('Riesgo Cardiovascular', 'Vigilancia para factores de riesgo cardiovascular', true, true, NULL),
('Conservación Auditiva', 'Programa de conservación auditiva por exposición a ruido', true, true, NULL),
('Conservación Visual', 'Vigilancia de salud visual ocupacional', true, true, NULL),
('Riesgo Osteomuscular', 'Vigilancia de desórdenes musculoesqueléticos', true, true, NULL),
('Riesgo Químico', 'Vigilancia por exposición a agentes químicos', true, true, NULL),
('Riesgo Biológico', 'Vigilancia por exposición a agentes biológicos', true, true, NULL),
('Riesgo Psicosocial', 'Vigilancia de factores de riesgo psicosocial', true, true, NULL);
