
-- Drop old evaluation tables
DROP TABLE IF EXISTS public.competency_evaluations CASCADE;
DROP TABLE IF EXISTS public.performance_evaluations CASCADE;

-- Drop old evaluation_status enum if exists (will recreate)
DROP TYPE IF EXISTS public.evaluation_status CASCADE;

-- Create evaluation status enum
CREATE TYPE public.evaluation_status AS ENUM ('pendiente', 'en_proceso', 'completada', 'cancelada');

-- Create evaluation_types table (master data, standard pattern)
CREATE TABLE public.evaluation_types (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL,
    description text,
    active boolean DEFAULT true,
    is_standard boolean DEFAULT false,
    tenant_id uuid REFERENCES public.tenants(id),
    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now()
);

ALTER TABLE public.evaluation_types ENABLE ROW LEVEL SECURITY;

-- Standard master data RLS (same pattern as event_types, course_types, etc.)
CREATE POLICY "Everyone can view standard evaluation types" ON public.evaluation_types FOR SELECT USING (is_standard = true);
CREATE POLICY "Super admins can manage all evaluation types" ON public.evaluation_types FOR ALL USING (is_super_admin(auth.uid()));
CREATE POLICY "Users can view tenant evaluation types" ON public.evaluation_types FOR SELECT USING (tenant_id = get_user_tenant_id(auth.uid()));
CREATE POLICY "Users can create tenant evaluation types" ON public.evaluation_types FOR INSERT WITH CHECK (tenant_id = get_user_tenant_id(auth.uid()) AND is_standard = false);
CREATE POLICY "Users can update evaluation types" ON public.evaluation_types FOR UPDATE USING ((tenant_id = get_user_tenant_id(auth.uid()) AND is_standard = false) OR (is_standard = true AND get_user_tenant_id(auth.uid()) IS NOT NULL));
CREATE POLICY "Users can delete tenant evaluation types" ON public.evaluation_types FOR DELETE USING (tenant_id = get_user_tenant_id(auth.uid()) AND is_standard = false);

-- Insert standard evaluation types
INSERT INTO public.evaluation_types (name, description, is_standard) VALUES
('Evaluación de Desempeño', 'Evaluación periódica del rendimiento laboral del empleado', true),
('Evaluación de Competencias', 'Evaluación del nivel de competencias técnicas y blandas', true),
('Evaluación 360°', 'Evaluación integral desde múltiples perspectivas (jefe, pares, subordinados)', true),
('Evaluación de Periodo de Prueba', 'Evaluación al finalizar el periodo de prueba del empleado', true),
('Clima Organizacional', 'Encuesta de satisfacción y clima laboral', true);

-- Create evaluation_templates table
CREATE TABLE public.evaluation_templates (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES public.tenants(id),
    name text NOT NULL,
    evaluation_type text NOT NULL,
    description text,
    scale_min integer NOT NULL DEFAULT 1,
    scale_max integer NOT NULL DEFAULT 5,
    periodicity text DEFAULT 'anual', -- trimestral, semestral, anual, unica
    is_anonymous boolean DEFAULT false,
    active boolean DEFAULT true,
    created_by uuid,
    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now()
);

ALTER TABLE public.evaluation_templates ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View evaluation_templates" ON public.evaluation_templates FOR SELECT USING (tenant_id = get_user_tenant_id(auth.uid()) AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'evaluaciones', 'ver')));
CREATE POLICY "Create evaluation_templates" ON public.evaluation_templates FOR INSERT WITH CHECK (tenant_id = get_user_tenant_id(auth.uid()) AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'evaluaciones', 'crear')));
CREATE POLICY "Update evaluation_templates" ON public.evaluation_templates FOR UPDATE USING (tenant_id = get_user_tenant_id(auth.uid()) AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'evaluaciones', 'editar')));
CREATE POLICY "Delete evaluation_templates" ON public.evaluation_templates FOR DELETE USING (tenant_id = get_user_tenant_id(auth.uid()) AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'evaluaciones', 'eliminar')));

-- Create evaluation_template_sections table
CREATE TABLE public.evaluation_template_sections (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    template_id uuid NOT NULL REFERENCES public.evaluation_templates(id) ON DELETE CASCADE,
    name text NOT NULL,
    description text,
    weight numeric(5,2) NOT NULL DEFAULT 100,
    sort_order integer NOT NULL DEFAULT 0,
    created_at timestamptz DEFAULT now()
);

ALTER TABLE public.evaluation_template_sections ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Tenant isolation for template_sections" ON public.evaluation_template_sections FOR ALL USING (EXISTS (SELECT 1 FROM evaluation_templates t WHERE t.id = evaluation_template_sections.template_id AND (t.tenant_id = get_user_tenant_id(auth.uid()) OR is_super_admin(auth.uid()))));

-- Create evaluation_template_criteria table
CREATE TABLE public.evaluation_template_criteria (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    section_id uuid NOT NULL REFERENCES public.evaluation_template_sections(id) ON DELETE CASCADE,
    name text NOT NULL,
    description text,
    sort_order integer NOT NULL DEFAULT 0,
    created_at timestamptz DEFAULT now()
);

ALTER TABLE public.evaluation_template_criteria ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Tenant isolation for template_criteria" ON public.evaluation_template_criteria FOR ALL USING (EXISTS (SELECT 1 FROM evaluation_template_sections s JOIN evaluation_templates t ON t.id = s.template_id WHERE s.id = evaluation_template_criteria.section_id AND (t.tenant_id = get_user_tenant_id(auth.uid()) OR is_super_admin(auth.uid()))));

-- Create evaluations table (instances)
CREATE TABLE public.evaluations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES public.tenants(id),
    template_id uuid NOT NULL REFERENCES public.evaluation_templates(id),
    employee_id uuid NOT NULL REFERENCES public.employees(id),
    evaluator_id uuid REFERENCES public.employees(id),
    period text NOT NULL,
    evaluation_date date NOT NULL,
    overall_score numeric(5,2),
    status evaluation_status DEFAULT 'pendiente',
    comments text,
    strengths text,
    areas_improvement text,
    action_plan text,
    created_by uuid,
    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now()
);

ALTER TABLE public.evaluations ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View evaluations" ON public.evaluations FOR SELECT USING (tenant_id = get_user_tenant_id(auth.uid()) AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'evaluaciones', 'ver')));
CREATE POLICY "Create evaluations" ON public.evaluations FOR INSERT WITH CHECK (tenant_id = get_user_tenant_id(auth.uid()) AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'evaluaciones', 'crear')));
CREATE POLICY "Update evaluations" ON public.evaluations FOR UPDATE USING (tenant_id = get_user_tenant_id(auth.uid()) AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'evaluaciones', 'editar')));
CREATE POLICY "Delete evaluations" ON public.evaluations FOR DELETE USING (tenant_id = get_user_tenant_id(auth.uid()) AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), 'evaluaciones', 'eliminar')));

-- Create evaluation_responses table
CREATE TABLE public.evaluation_responses (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    evaluation_id uuid NOT NULL REFERENCES public.evaluations(id) ON DELETE CASCADE,
    criterion_id uuid NOT NULL REFERENCES public.evaluation_template_criteria(id),
    score numeric(5,2),
    comments text,
    created_at timestamptz DEFAULT now()
);

ALTER TABLE public.evaluation_responses ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Tenant isolation for evaluation_responses" ON public.evaluation_responses FOR ALL USING (EXISTS (SELECT 1 FROM evaluations e WHERE e.id = evaluation_responses.evaluation_id AND (e.tenant_id = get_user_tenant_id(auth.uid()) OR is_super_admin(auth.uid()))));

-- Add updated_at triggers
CREATE TRIGGER update_evaluation_types_updated_at BEFORE UPDATE ON public.evaluation_types FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER update_evaluation_templates_updated_at BEFORE UPDATE ON public.evaluation_templates FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER update_evaluations_updated_at BEFORE UPDATE ON public.evaluations FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Insert evaluaciones module if not exists
INSERT INTO public.modules (code, name, description, icon)
VALUES ('evaluaciones', 'Evaluaciones', 'Módulo unificado de evaluaciones de desempeño, competencias y clima', 'ClipboardCheck')
ON CONFLICT (code) DO UPDATE SET name = 'Evaluaciones', description = 'Módulo unificado de evaluaciones de desempeño, competencias y clima';
