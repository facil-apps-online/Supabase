
-- Add column to attention_services
ALTER TABLE public.attention_services
ADD COLUMN client_treatment_session_id UUID NULL;

-- Add foreign key constraint to attention_services
ALTER TABLE public.attention_services
ADD CONSTRAINT fk_attention_services_client_treatment_session
FOREIGN KEY (client_treatment_session_id)
REFERENCES public.client_treatment_sessions(id)
ON DELETE SET NULL;

-- Add column to attention_products
ALTER TABLE public.attention_products
ADD COLUMN client_treatment_session_id UUID NULL;

-- Add foreign key constraint to attention_products
ALTER TABLE public.attention_products
ADD CONSTRAINT fk_attention_products_client_treatment_session
FOREIGN KEY (client_treatment_session_id)
REFERENCES public.client_treatment_sessions(id)
ON DELETE SET NULL;
