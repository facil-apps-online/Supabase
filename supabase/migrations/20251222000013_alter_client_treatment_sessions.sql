-- 1. Eliminar la constraint existente
ALTER TABLE public.client_treatment_sessions
DROP CONSTRAINT client_treatment_sessions_status_check;

-- 2. Añadir la nueva constraint con el estado 'Cita Asignada'
ALTER TABLE public.client_treatment_sessions
ADD CONSTRAINT client_treatment_sessions_status_check
CHECK (status = ANY (ARRAY['pending'::text, 'completed'::text, 'Cita Asignada'::text]));

-- 3. Añadir la Foreign Key a attention_id para manejar desvinculación automática (opcional pero recomendado)
-- Se asegura que si una atención es eliminada de la base de datos por alguna razón,
-- el campo attention_id en la sesión se vuelva NULL en lugar de causar un error de FK.
ALTER TABLE public.client_treatment_sessions
ADD CONSTRAINT fk_client_treatment_sessions_attention
FOREIGN KEY (attention_id) REFERENCES public.attentions(id) ON DELETE SET NULL;
