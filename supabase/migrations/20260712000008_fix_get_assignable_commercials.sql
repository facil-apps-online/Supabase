-- Migration: 20260712000008_fix_get_assignable_commercials.sql

DROP FUNCTION IF EXISTS "public"."get_assignable_commercials"("p_tenant_id" "uuid");

CREATE OR REPLACE FUNCTION "public"."get_assignable_commercials"("p_tenant_id" "uuid", p_platform_id uuid DEFAULT NULL) RETURNS TABLE("user_id" "uuid", "email" "text", "first_name" "text", "last_name" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  vendor_role_id UUID;
BEGIN
  SELECT id INTO vendor_role_id FROM public.roles WHERE name = 'tenant_vendor' LIMIT 1;

  RETURN QUERY
  SELECT
      au.id AS user_id,
      au.email::text,
      (au.raw_user_meta_data ->> 'first_name') AS first_name,
      (au.raw_user_meta_data ->> 'last_name') AS last_name
  FROM
      auth.users AS au
  WHERE au.id IN (
    -- Select only users assigned as vendors in this tenant
    SELECT ua.user_id FROM public.user_assignments ua WHERE ua.tenant_id = p_tenant_id AND ua.role_id = vendor_role_id
    -- TODO: AND ua.platform_id = p_platform_id
  );
END;
$$;
