-- Add foreign key constraint for product_id
ALTER TABLE public.treatment_session_items
ADD CONSTRAINT treatment_session_items_product_id_fkey
FOREIGN KEY (product_id)
REFERENCES public.products(id)
ON DELETE SET NULL;

-- Add foreign key constraint for service_id
ALTER TABLE public.treatment_session_items
ADD CONSTRAINT treatment_session_items_service_id_fkey
FOREIGN KEY (service_id)
REFERENCES public.services(id)
ON DELETE SET NULL;
