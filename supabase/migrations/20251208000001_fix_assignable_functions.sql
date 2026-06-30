-- Migration: 20251208000001_fix_assignable_functions.sql
-- Fix "operator does not exist: text ->> unknown" error in get_assignable_professionals and get_assignable_commercials functions.

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
      (au.raw_user_meta_data::jsonb ->> 'first_name' || ' ' || au.raw_user_meta_data::jsonb ->> 'last_name') AS full_name,
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
      (au.raw_user_meta_data::jsonb ->> 'first_name' || ' ' || au.raw_user_meta_data::jsonb ->> 'last_name') AS full_name,
      au.email
  FROM
      auth.users AS au
  WHERE au.id IN (
    -- Select only users assigned as vendors in this tenant
    SELECT ua.user_id FROM public.user_assignments ua WHERE ua.tenant_id = p_tenant_id AND ua.role_id = vendor_role_id
  );
END;
$$;