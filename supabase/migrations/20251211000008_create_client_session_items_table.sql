-- This migration creates the 'client_treatment_session_items' table, which is the
-- missing link for storing the specific products and services for a client's assigned session.

CREATE TABLE public.client_treatment_session_items (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    client_treatment_session_id uuid NOT NULL,
    product_id uuid NULL,
    service_id uuid NULL,
    quantity integer NOT NULL DEFAULT 1,
    notes text NULL,
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    updated_at timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT client_treatment_session_items_pkey PRIMARY KEY (id),
    CONSTRAINT client_treatment_session_items_client_treatment_session_id_fkey FOREIGN KEY (client_treatment_session_id) REFERENCES public.client_treatment_sessions(id) ON DELETE CASCADE,
    CONSTRAINT client_treatment_session_items_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE SET NULL,
    CONSTRAINT client_treatment_session_items_service_id_fkey FOREIGN KEY (service_id) REFERENCES public.services(id) ON DELETE SET NULL,
    CONSTRAINT chk_one_item CHECK (product_id IS NOT NULL OR service_id IS NOT NULL)
);

-- Add comments to the new table and columns for clarity
COMMENT ON TABLE public.client_treatment_session_items IS 'Stores the specific items (products or services) associated with a particular client treatment session.';
COMMENT ON COLUMN public.client_treatment_session_items.client_treatment_session_id IS 'Links to the parent client treatment session.';
COMMENT ON COLUMN public.client_treatment_session_items.product_id IS 'Link to the products table, if the item is a product.';
COMMENT ON COLUMN public.client_treatment_session_items.service_id IS 'Link to the services table, if the item is a service.';
COMMENT ON COLUMN public.client_treatment_session_items.quantity IS 'The quantity of the product or service for this session.';
