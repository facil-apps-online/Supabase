ALTER TABLE public.signed_consents
ADD COLUMN IF NOT EXISTS attention_service_id uuid NULL;

ALTER TABLE public.signed_consents
ADD CONSTRAINT fk_signed_consents_attention_service
  FOREIGN KEY (attention_service_id) REFERENCES public.attention_services (id) ON DELETE SET NULL;