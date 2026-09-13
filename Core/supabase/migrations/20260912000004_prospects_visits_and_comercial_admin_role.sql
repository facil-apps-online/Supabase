-- Migration: Prospectos + bitácora de visitas, y rol global comercial_admin.
-- Un vendedor trabaja un prospecto (llamadas/visitas) ANTES de decidir enviarle una
-- invitación formal; hasta ahora no había dónde registrar ese seguimiento.

BEGIN;

-- Rol global nuevo (mismo patrón que vendor/investor/app_super_admin).
INSERT INTO public.roles (id, name, display_name, description, tenant_id, platform_id)
VALUES (
  gen_random_uuid(),
  'comercial_admin',
  'Administrador Comercial',
  'Ve información de plataformas y controla su equipo comercial (vendedores, prospectos, visitas e invitaciones).',
  NULL,
  NULL
)
ON CONFLICT DO NOTHING;

CREATE TABLE public.vendor_prospects (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_user_id      uuid NOT NULL,
  platform_id         uuid NOT NULL REFERENCES public.platforms(id),
  first_name          text NOT NULL,
  last_name           text,
  phone               text,
  email               text,
  company_name        text,
  status              text NOT NULL DEFAULT 'nuevo'
    CHECK (status IN ('nuevo','en_contacto','interesado','no_interesado','reagendar','convertido')),
  last_visit_at       timestamptz,
  invitation_id       uuid REFERENCES public.vendor_invitations(id),
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.vendor_prospect_visits (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  prospect_id    uuid NOT NULL REFERENCES public.vendor_prospects(id) ON DELETE CASCADE,
  vendor_user_id uuid NOT NULL,
  visit_date     timestamptz NOT NULL DEFAULT now(),
  status         text NOT NULL
    CHECK (status IN ('nuevo','en_contacto','interesado','no_interesado','reagendar','convertido')),
  notes          text,
  created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_vendor_prospects_vendor ON public.vendor_prospects (vendor_user_id, status);
CREATE INDEX idx_vendor_prospects_platform ON public.vendor_prospects (platform_id, status);
CREATE INDEX idx_vendor_prospect_visits_prospect ON public.vendor_prospect_visits (prospect_id, visit_date DESC);

ALTER TABLE public.vendor_prospects ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vendor_prospect_visits ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Allow ALL for super_admin" ON public.vendor_prospects
  USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON public.vendor_prospect_visits
  USING (is_super_admin()) WITH CHECK (is_super_admin());

CREATE TRIGGER trg_vendor_prospects_updated_at
  BEFORE UPDATE ON public.vendor_prospects
  FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();

COMMIT;
