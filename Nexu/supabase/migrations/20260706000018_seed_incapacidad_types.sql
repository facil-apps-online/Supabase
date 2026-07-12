-- ==============================================================
-- Seed standard incapacidad_types
-- ==============================================================

INSERT INTO public.incapacidad_types (code, name, description, is_standard)
SELECT 'EG', 'Incapacidad por enfermedad general', 'Incapacidad por enfermedad general', true
WHERE NOT EXISTS (SELECT 1 FROM public.incapacidad_types WHERE code = 'EG' AND is_standard = true);

INSERT INTO public.incapacidad_types (code, name, description, is_standard)
SELECT 'LM', 'Licencia de maternidad', 'Licencia de maternidad', true
WHERE NOT EXISTS (SELECT 1 FROM public.incapacidad_types WHERE code = 'LM' AND is_standard = true);

INSERT INTO public.incapacidad_types (code, name, description, is_standard)
SELECT 'AT', 'Accidente de trabajo', 'Accidente de trabajo', true
WHERE NOT EXISTS (SELECT 1 FROM public.incapacidad_types WHERE code = 'AT' AND is_standard = true);
