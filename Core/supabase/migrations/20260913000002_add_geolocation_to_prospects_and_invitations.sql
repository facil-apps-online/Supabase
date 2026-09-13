-- Migration: Coordenadas de geolocalización en prospectos e invitaciones, capturadas por el
-- mismo autocompletado de direcciones de Google Maps que ya usa "Crear Tenant" — mismo tipo
-- de columna que public.tenants.latitude/longitude.

ALTER TABLE public.vendor_prospects
  ADD COLUMN IF NOT EXISTS latitude  numeric(10,7),
  ADD COLUMN IF NOT EXISTS longitude numeric(10,7);

ALTER TABLE public.vendor_invitations
  ADD COLUMN IF NOT EXISTS latitude  numeric(10,7),
  ADD COLUMN IF NOT EXISTS longitude numeric(10,7);
