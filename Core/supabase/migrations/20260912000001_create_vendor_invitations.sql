-- Migration: Mini CRM de vendedores — tabla de invitaciones y tope global de días de prueba.
-- Affects: public.vendor_invitations, public.global_settings

BEGIN;

CREATE TABLE public.vendor_invitations (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_user_id      uuid NOT NULL,
  platform_id         uuid NOT NULL REFERENCES public.platforms(id),
  prospect_first_name text NOT NULL,
  prospect_last_name  text,
  prospect_email      text,
  prospect_phone      text,
  company_name        text,
  tax_id              text,
  invite_token        text NOT NULL UNIQUE,
  invite_url          text NOT NULL,
  status              text NOT NULL DEFAULT 'nuevo'
    CHECK (status IN ('nuevo','en_contacto','interesado','onboarding_enviado',
                       'cuenta_creada','activo','activo_con_plan','perdido','duplicado')),
  trial_days_override integer,
  tenant_id           uuid REFERENCES public.tenants(id),
  notes               text,
  expires_at          timestamptz NOT NULL DEFAULT (now() + interval '30 days'),
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_vendor_invitations_vendor ON public.vendor_invitations (vendor_user_id, status);
CREATE INDEX idx_vendor_invitations_platform ON public.vendor_invitations (platform_id, status);

ALTER TABLE public.vendor_invitations ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Allow ALL for super_admin" ON public.vendor_invitations
  USING (is_super_admin()) WITH CHECK (is_super_admin());

CREATE TRIGGER trg_vendor_invitations_updated_at
  BEFORE UPDATE ON public.vendor_invitations
  FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();

ALTER TABLE public.global_settings
  ADD COLUMN IF NOT EXISTS max_vendor_trial_days integer NOT NULL DEFAULT 30;

COMMIT;
