-- Add address fields to clients table
ALTER TABLE public.clients
ADD COLUMN address_line_1 text null,
ADD COLUMN address_line_2 text null,
ADD COLUMN city text null,
ADD COLUMN state text null,
ADD COLUMN postal_code text null,
ADD COLUMN country text null,
ADD COLUMN latitude double precision null,
ADD COLUMN longitude double precision null;

-- Create client_addresses table
CREATE TABLE public.client_addresses (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  client_id uuid NOT NULL,
  address_line_1 text NULL,
  address_line_2 text NULL,
  city text NULL,
  state text NULL,
  postal_code text NULL,
  country text NULL,
  latitude double precision NULL,
  longitude double precision NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  tenant_id uuid NOT NULL,
  name text NULL,
  CONSTRAINT client_addresses_pkey PRIMARY KEY (id),
  CONSTRAINT client_addresses_client_id_fkey FOREIGN KEY (client_id) REFERENCES clients(id) ON DELETE CASCADE,
  CONSTRAINT client_addresses_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES tenants(id) ON DELETE CASCADE
);

-- Create client_contacts table
CREATE TABLE public.client_contacts (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  client_id uuid NOT NULL,
  name text NOT NULL,
  email text NULL,
  phone text NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  tenant_id uuid NOT NULL,
  contact_type_id uuid NOT NULL,
  CONSTRAINT client_contacts_pkey PRIMARY KEY (id),
  CONSTRAINT client_contacts_contact_type_id_fkey FOREIGN KEY (contact_type_id) REFERENCES contact_types(id) ON DELETE SET NULL,
  CONSTRAINT client_contacts_client_id_fkey FOREIGN KEY (client_id) REFERENCES clients(id) ON DELETE CASCADE,
  CONSTRAINT client_contacts_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES tenants(id) ON DELETE CASCADE
);