-- Migration: 20251208000002_split_full_name_in_assignable_functions.sql
-- Modify get_assignable_professionals and get_assignable_commercials to return first_name and last_name separately.
-- This version drops the functions before creating them to allow changing the return signature.

DROP FUNCTION IF EXISTS public.get_assignable_professionals(uuid);
DROP FUNCTION IF EXISTS public.get_assignable_commercials(uuid);

CREATE FUNCTION public.get_assignable_professionals(p_tenant_id uuid)
RETURNS TABLE (user_id uuid, email text, first_name text, last_name text)
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
      au.email,
      (au.raw_user_meta_data ->> 'first_name') AS first_name,
      (au.raw_user_meta_data ->> 'last_name') AS last_name
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

CREATE FUNCTION public.get_assignable_commercials(p_tenant_id uuid)
RETURNS TABLE (user_id uuid, email text, first_name text, last_name text)
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
      au.email,
      (au.raw_user_meta_data ->> 'first_name') AS first_name,
      (au.raw_user_meta_data ->> 'last_name') AS last_name
  FROM
      auth.users AS au
  WHERE au.id IN (
    -- Select only users assigned as vendors in this tenant
    SELECT ua.user_id FROM public.user_assignments ua WHERE ua.tenant_id = p_tenant_id AND ua.role_id = vendor_role_id
  );
END;
$$;
