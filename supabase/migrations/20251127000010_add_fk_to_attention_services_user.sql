ALTER TABLE public.attention_services
ADD CONSTRAINT fk_attention_services_user
FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE SET NULL;

COMMENT ON CONSTRAINT fk_attention_services_user ON public.attention_services IS 'Links the service to the professional (user) who performed it.';
