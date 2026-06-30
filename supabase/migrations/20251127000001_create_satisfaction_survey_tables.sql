-- Migration: Create satisfaction survey tables

-- Create table for satisfaction_surveys
CREATE TABLE public.satisfaction_surveys (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  attention_id uuid NOT NULL,
  client_id uuid NOT NULL,
  tenant_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  survey_token uuid NOT NULL DEFAULT gen_random_uuid(),
  status text NOT NULL DEFAULT 'generated'::text,
  submitted_at timestamp with time zone NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT satisfaction_surveys_pkey PRIMARY KEY (id),
  CONSTRAINT fk_satisfaction_surveys_attention FOREIGN KEY (attention_id) REFERENCES public.attentions (id) ON DELETE CASCADE,
  CONSTRAINT fk_satisfaction_surveys_client FOREIGN KEY (client_id) REFERENCES public.clients (id) ON DELETE CASCADE,
  CONSTRAINT fk_satisfaction_surveys_tenant FOREIGN KEY (tenant_id) REFERENCES public.tenants (id) ON DELETE CASCADE,
  CONSTRAINT fk_satisfaction_surveys_branch FOREIGN KEY (branch_id) REFERENCES public.branches (id) ON DELETE CASCADE,
  CONSTRAINT satisfaction_surveys_survey_token_key UNIQUE (survey_token),
  CONSTRAINT satisfaction_surveys_status_check CHECK (
    (
      status = ANY (
        ARRAY[
          'generated'::text,
          'sent'::text,
          'completed'::text,
          'expired'::text
        ]
      )
    )
  )
) TABLESPACE pg_default;

-- Add indexes
CREATE INDEX IF NOT EXISTS idx_satisfaction_surveys_attention_id ON public.satisfaction_surveys USING btree (attention_id) TABLESPACE pg_default;
CREATE INDEX IF NOT EXISTS idx_satisfaction_surveys_survey_token ON public.satisfaction_surveys USING btree (survey_token) TABLESPACE pg_default;
CREATE INDEX IF NOT EXISTS idx_satisfaction_surveys_tenant_id ON public.satisfaction_surveys USING btree (tenant_id) TABLESPACE pg_default;

-- Add triggers
CREATE TRIGGER audit_satisfaction_surveys_changes
AFTER INSERT OR DELETE OR UPDATE ON public.satisfaction_surveys
FOR EACH ROW EXECUTE FUNCTION audit_trigger_function();

CREATE TRIGGER update_satisfaction_surveys_updated_at
BEFORE UPDATE ON public.satisfaction_surveys
FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Create table for satisfaction_survey_ratings
CREATE TABLE public.satisfaction_survey_ratings (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  survey_id uuid NOT NULL,
  attention_service_id uuid NOT NULL,
  rating integer NOT NULL,
  comments text NULL,
  tenant_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT satisfaction_survey_ratings_pkey PRIMARY KEY (id),
  CONSTRAINT fk_satisfaction_survey_ratings_survey FOREIGN KEY (survey_id) REFERENCES public.satisfaction_surveys (id) ON DELETE CASCADE,
  CONSTRAINT fk_satisfaction_survey_ratings_attention_service FOREIGN KEY (attention_service_id) REFERENCES public.attention_services (id) ON DELETE CASCADE,
  CONSTRAINT fk_satisfaction_survey_ratings_tenant FOREIGN KEY (tenant_id) REFERENCES public.tenants (id) ON DELETE CASCADE,
  CONSTRAINT fk_satisfaction_survey_ratings_branch FOREIGN KEY (branch_id) REFERENCES public.branches (id) ON DELETE CASCADE,
  CONSTRAINT satisfaction_survey_ratings_rating_check CHECK (
    (rating >= 1 AND rating <= 5)
  )
) TABLESPACE pg_default;

-- Add indexes
CREATE INDEX IF NOT EXISTS idx_satisfaction_survey_ratings_survey_id ON public.satisfaction_survey_ratings USING btree (survey_id) TABLESPACE pg_default;
CREATE INDEX IF NOT EXISTS idx_satisfaction_survey_ratings_attention_service_id ON public.satisfaction_survey_ratings USING btree (attention_service_id) TABLESPACE pg_default;
CREATE INDEX IF NOT EXISTS idx_satisfaction_survey_ratings_tenant_id ON public.satisfaction_survey_ratings USING btree (tenant_id) TABLESPACE pg_default;

-- Add triggers
CREATE TRIGGER audit_satisfaction_survey_ratings_changes
AFTER INSERT OR DELETE OR UPDATE ON public.satisfaction_survey_ratings
FOR EACH ROW EXECUTE FUNCTION audit_trigger_function();

CREATE TRIGGER update_satisfaction_survey_ratings_updated_at
BEFORE UPDATE ON public.satisfaction_survey_ratings
FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
