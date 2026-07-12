-- Seed standard document types for NexuHR (employee management)
-- Only CC, TI, and NIT are relevant; remove CE and PA

-- Remove non-relevant standard types if they were created
DELETE FROM public.document_types WHERE code IN ('CE', 'PA') AND is_standard = true;

-- Ensure CC and TI exist as standard
INSERT INTO public.document_types (code, name, is_standard, tenant_id, active)
VALUES 
  ('CC', 'Cédula de Ciudadanía', true, NULL, true),
  ('TI', 'Tarjeta de Identidad', true, NULL, true)
ON CONFLICT (code) WHERE is_standard = true DO NOTHING;

-- Ensure NIT exists as standard
INSERT INTO public.document_types (code, name, is_standard, tenant_id, active)
VALUES ('NIT', 'Nit', true, NULL, true)
ON CONFLICT (code) WHERE is_standard = true DO NOTHING;
