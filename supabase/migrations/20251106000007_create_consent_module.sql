-- 1. Tabla para las plantillas de consentimientos informados
CREATE TABLE public.informed_consent_templates (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    name text NOT NULL,
    content text NULL,
    fields jsonb NULL,
    is_active boolean NOT NULL DEFAULT true,
    tenant_id uuid NOT NULL,
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    updated_at timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT informed_consent_templates_pkey PRIMARY KEY (id),
    CONSTRAINT fk_informed_consent_templates_tenant FOREIGN KEY (tenant_id) REFERENCES tenants(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_ict_tenant_id ON public.informed_consent_templates USING btree (tenant_id) TABLESPACE pg_default;

CREATE TRIGGER update_informed_consent_templates_updated_at
BEFORE UPDATE ON public.informed_consent_templates
FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- 2. Tabla para los consentimientos firmados (el registro del evento)
CREATE TABLE public.signed_consents (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    appointment_id uuid NOT NULL,
    client_id uuid NOT NULL,
    professional_id uuid NOT NULL,
    template_id uuid NOT NULL,
    professional_observations text NULL,
    tenant_id uuid NOT NULL,
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    updated_at timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT signed_consents_pkey PRIMARY KEY (id),
    CONSTRAINT fk_signed_consents_appointment FOREIGN KEY (appointment_id) REFERENCES appointments(id) ON DELETE RESTRICT,
    CONSTRAINT fk_signed_consents_client FOREIGN KEY (client_id) REFERENCES clients(id) ON DELETE RESTRICT,
    CONSTRAINT fk_signed_consents_professional FOREIGN KEY (professional_id) REFERENCES auth.users(id) ON DELETE RESTRICT,
    CONSTRAINT fk_signed_consents_template FOREIGN KEY (template_id) REFERENCES informed_consent_templates(id) ON DELETE RESTRICT,
    CONSTRAINT fk_signed_consents_tenant FOREIGN KEY (tenant_id) REFERENCES tenants(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_sc_appointment_id ON public.signed_consents USING btree (appointment_id) TABLESPACE pg_default;
CREATE INDEX IF NOT EXISTS idx_sc_client_id ON public.signed_consents USING btree (client_id) TABLESPACE pg_default;
CREATE INDEX IF NOT EXISTS idx_sc_tenant_id ON public.signed_consents USING btree (tenant_id) TABLESPACE pg_default;

CREATE TRIGGER update_signed_consents_updated_at
BEFORE UPDATE ON public.signed_consents
FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- 3. Tabla para las evidencias de firma (el archivo en Google Drive)
CREATE TABLE public.consent_signatures (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    signed_consent_id uuid NOT NULL,
    google_drive_file_id text NOT NULL,
    file_name text NOT NULL,
    mime_type text NULL,
    tenant_id uuid NOT NULL,
    branch_id uuid NOT NULL,
    user_id uuid NULL,
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    updated_at timestamp with time zone NOT NULL DEFAULT now(),
    file_size bigint NULL,
    CONSTRAINT consent_signatures_pkey PRIMARY KEY (id),
    CONSTRAINT fk_consent_signatures_signed_consent FOREIGN KEY (signed_consent_id) REFERENCES signed_consents(id) ON DELETE CASCADE,
    CONSTRAINT fk_consent_signatures_branch FOREIGN KEY (branch_id) REFERENCES branches(id) ON DELETE CASCADE,
    CONSTRAINT fk_consent_signatures_tenant FOREIGN KEY (tenant_id) REFERENCES tenants(id) ON DELETE CASCADE,
    CONSTRAINT fk_consent_signatures_user FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_cs_signed_consent_id ON public.consent_signatures USING btree (signed_consent_id) TABLESPACE pg_default;
CREATE INDEX IF NOT EXISTS idx_cs_tenant_id ON public.consent_signatures USING btree (tenant_id) TABLESPACE pg_default;

CREATE TRIGGER audit_consent_signatures_changes
AFTER INSERT OR DELETE OR UPDATE ON public.consent_signatures
FOR EACH ROW EXECUTE FUNCTION audit_trigger_function();

CREATE TRIGGER update_consent_signatures_updated_at
BEFORE UPDATE ON public.consent_signatures
FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();