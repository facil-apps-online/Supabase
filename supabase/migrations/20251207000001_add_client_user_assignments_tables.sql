
-- Migration: 20251207000001_add_client_user_assignments_tables.sql
-- Add client_professionals and client_commercials tables

-- Table for client professionals
CREATE TABLE public.client_professionals (
  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  tenant_id uuid NOT NULL,
  client_id uuid NOT NULL,
  user_id uuid NOT NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT client_professionals_pkey PRIMARY KEY (id),
  CONSTRAINT client_professionals_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants (id) ON DELETE CASCADE,
  CONSTRAINT client_professionals_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.clients (id) ON DELETE CASCADE,
  CONSTRAINT client_professionals_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE,
  CONSTRAINT client_professionals_unique_assignment UNIQUE (tenant_id, client_id, user_id)
);

-- Table for client commercials
CREATE TABLE public.client_commercials (
  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  tenant_id uuid NOT NULL,
  client_id uuid NOT NULL,
  user_id uuid NOT NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT client_commercials_pkey PRIMARY KEY (id),
  CONSTRAINT client_commercials_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants (id) ON DELETE CASCADE,
  CONSTRAINT client_commercials_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.clients (id) ON DELETE CASCADE,
  CONSTRAINT client_commercials_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE,
  CONSTRAINT client_commercials_unique_assignment UNIQUE (tenant_id, client_id, user_id)
);

-- RLS Policies for client_professionals
ALTER TABLE public.client_professionals ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Tenant users can manage client_professionals"
ON public.client_professionals FOR ALL
USING ( (
  SELECT auth.uid() IN (
    SELECT ua.user_id FROM public.user_assignments AS ua WHERE ua.tenant_id = client_professionals.tenant_id
  )
) );

-- RLS Policies for client_commercials
ALTER TABLE public.client_commercials ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Tenant users can manage client_commercials"
ON public.client_commercials FOR ALL
USING ( (
  SELECT auth.uid() IN (
    SELECT ua.user_id FROM public.user_assignments AS ua WHERE ua.tenant_id = client_commercials.tenant_id
  )
) );


-- Functions for getting assignable users based on roles

-- This function gets users who are NOT vendors.
CREATE OR REPLACE FUNCTION public.get_assignable_professionals(p_tenant_id uuid)
RETURNS TABLE (user_id uuid, full_name text, email text)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  vendor_role_id UUID;
BEGIN
  SELECT id INTO vendor_role_id FROM public.roles WHERE name = 'tenant_vendor' LIMIT 1;

  RETURN QUERY
  SELECT
      au.id AS user_id,
      (au.raw_user_meta_data ->> 'first_name' || ' ' || au.raw_user_meta_data ->> 'last_name') AS full_name,
      au.email
  FROM
      auth.users AS au
  WHERE au.id IN (
    -- Select all users assigned to this tenant
    SELECT ua.user_id FROM public.user_assignments ua WHERE ua.tenant_id = p_tenant_id
  ) AND au.id NOT IN (
    -- Exclude users who have the 'tenant_vendor' role in this tenant
    SELECT ua.user_id FROM public.user_assignments ua WHERE ua.tenant_id = p_tenant_id AND ua.role_id = vendor_role_id
  );
END;
$$;

-- This function gets ONLY users who are vendors.
CREATE OR REPLACE FUNCTION public.get_assignable_commercials(p_tenant_id uuid)
RETURNS TABLE (user_id uuid, full_name text, email text)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  vendor_role_id UUID;
BEGIN
  SELECT id INTO vendor_role_id FROM public.roles WHERE name = 'tenant_vendor' LIMIT 1;

  RETURN QUERY
  SELECT
      au.id AS user_id,
      (au.raw_user_meta_data ->> 'first_name' || ' ' || au.raw_user_meta_data ->> 'last_name') AS full_name,
      au.email
  FROM
      auth.users AS au
  WHERE au.id IN (
    -- Select only users assigned as vendors in this tenant
    SELECT ua.user_id FROM public.user_assignments ua WHERE ua.tenant_id = p_tenant_id AND ua.role_id = vendor_role_id
  );
END;
$$;
