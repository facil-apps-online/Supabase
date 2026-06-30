CREATE TABLE public.billing_entities (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    legal_name text NOT NULL,
    tax_id text NULL,
    billing_address_line1 text NULL,
    billing_address_line2 text NULL,
    billing_city text NULL,
    billing_state text NULL,
    billing_postal_code text NULL,
    billing_country_id uuid NULL,
    contact_email text NULL,
    contact_phone text NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT billing_entities_pkey PRIMARY KEY (id),
    CONSTRAINT billing_entities_billing_country_id_fkey FOREIGN KEY (billing_country_id) REFERENCES public.countries(id)
);

-- Enable RLS
ALTER TABLE public.billing_entities ENABLE ROW LEVEL SECURITY;

-- Policies for RLS: Allow super_admins to do everything
CREATE POLICY "Allow ALL for super_admin"
ON public.billing_entities
FOR ALL
USING (is_super_admin())
WITH CHECK (is_super_admin());

-- This is a trick to ensure only one row can ever be created in the table.
-- We create a unique index on a constant value. The second attempt to insert will fail.
CREATE UNIQUE INDEX one_billing_entity_idx ON public.billing_entities ((1));