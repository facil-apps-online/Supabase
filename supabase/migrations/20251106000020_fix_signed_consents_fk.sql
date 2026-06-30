ALTER TABLE public.signed_consents
DROP CONSTRAINT IF EXISTS fk_signed_consents_appointment;

ALTER TABLE public.signed_consents
ADD CONSTRAINT fk_signed_consents_attention
  FOREIGN KEY (attention_id) REFERENCES public.attentions (id) ON DELETE RESTRICT;