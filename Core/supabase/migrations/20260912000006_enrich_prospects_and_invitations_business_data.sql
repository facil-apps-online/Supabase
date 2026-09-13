-- Migration: Capturar datos de negocio del prospecto (como el formulario de creación de
-- tenant) desde el momento del primer contacto, para no tener que volver a digitarlos al
-- invitar o dar de alta al cliente.

BEGIN;

ALTER TABLE public.vendor_prospects
  ADD COLUMN IF NOT EXISTS legal_name              text,
  ADD COLUMN IF NOT EXISTS tax_id                  text,
  ADD COLUMN IF NOT EXISTS whatsapp_phone          text,
  ADD COLUMN IF NOT EXISTS billing_address         text,
  ADD COLUMN IF NOT EXISTS einvoicing_email        text,
  ADD COLUMN IF NOT EXISTS physical_address_line1  text,
  ADD COLUMN IF NOT EXISTS physical_address_line2  text,
  ADD COLUMN IF NOT EXISTS physical_city           text,
  ADD COLUMN IF NOT EXISTS physical_state          text,
  ADD COLUMN IF NOT EXISTS physical_postal_code    text,
  ADD COLUMN IF NOT EXISTS website                 text;

ALTER TABLE public.vendor_invitations
  ADD COLUMN IF NOT EXISTS legal_name              text,
  ADD COLUMN IF NOT EXISTS whatsapp_phone          text,
  ADD COLUMN IF NOT EXISTS billing_address         text,
  ADD COLUMN IF NOT EXISTS einvoicing_email        text,
  ADD COLUMN IF NOT EXISTS physical_address_line1  text,
  ADD COLUMN IF NOT EXISTS physical_address_line2  text,
  ADD COLUMN IF NOT EXISTS physical_city           text,
  ADD COLUMN IF NOT EXISTS physical_state          text,
  ADD COLUMN IF NOT EXISTS physical_postal_code    text,
  ADD COLUMN IF NOT EXISTS website                 text;

COMMIT;
