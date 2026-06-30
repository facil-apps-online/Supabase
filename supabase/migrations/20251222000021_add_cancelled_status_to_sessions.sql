-- 1. Eliminar la constraint existente
ALTER TABLE public.client_treatment_sessions
DROP CONSTRAINT client_treatment_sessions_status_check;

-- 2. Añadir la nueva constraint con el estado 'Cancelada'
ALTER TABLE public.client_treatment_sessions
ADD CONSTRAINT client_treatment_sessions_status_check
CHECK (status = ANY (ARRAY['pending'::text, 'completed'::text, 'Cita Asignada'::text, 'Cancelada'::text]));
