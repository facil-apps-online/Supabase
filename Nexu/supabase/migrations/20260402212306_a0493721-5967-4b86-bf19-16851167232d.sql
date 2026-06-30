ALTER TABLE public.evaluation_templates 
ADD COLUMN assignment_mode text NOT NULL DEFAULT 'individual';

COMMENT ON COLUMN public.evaluation_templates.assignment_mode IS 'Modes: individual, bulk, department, self, 360';
