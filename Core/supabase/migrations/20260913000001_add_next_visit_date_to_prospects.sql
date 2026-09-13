-- Migration: Fecha de próxima visita en prospectos, para poder mostrar "pendientes de hoy"
-- por vendedor en vez de que el seguimiento dependa de la memoria de cada quien.

ALTER TABLE public.vendor_prospects
  ADD COLUMN IF NOT EXISTS next_visit_at timestamptz;

CREATE INDEX IF NOT EXISTS idx_vendor_prospects_next_visit
  ON public.vendor_prospects (vendor_user_id, next_visit_at)
  WHERE next_visit_at IS NOT NULL;
