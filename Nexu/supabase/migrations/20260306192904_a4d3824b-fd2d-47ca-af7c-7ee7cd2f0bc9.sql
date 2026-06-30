
-- Add response type configuration to criteria
ALTER TABLE public.evaluation_template_criteria
  ADD COLUMN response_type text NOT NULL DEFAULT 'scale',
  ADD COLUMN options jsonb DEFAULT NULL,
  ADD COLUMN correct_answer text DEFAULT NULL;

-- Add response_value to store non-numeric answers (selected option, yes/no, text)
ALTER TABLE public.evaluation_responses
  ADD COLUMN response_value text DEFAULT NULL;

COMMENT ON COLUMN public.evaluation_template_criteria.response_type IS 'Type: scale, multiple_choice, single_choice, yes_no, open_text';
COMMENT ON COLUMN public.evaluation_template_criteria.options IS 'JSON array of option labels for choice-type questions, e.g. ["Opción A","Opción B"]';
COMMENT ON COLUMN public.evaluation_template_criteria.correct_answer IS 'Expected correct answer for auto-grading (optional)';
