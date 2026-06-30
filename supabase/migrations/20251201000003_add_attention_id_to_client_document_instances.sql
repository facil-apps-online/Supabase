ALTER TABLE public.client_document_instances
ADD COLUMN attention_id UUID NULL,
ADD CONSTRAINT fk_client_document_instances_attention
  FOREIGN KEY (attention_id) REFERENCES public.attentions (id) ON DELETE SET NULL;

COMMENT ON COLUMN public.client_document_instances.attention_id IS 'Optional link to the attention where this document was filled out.';