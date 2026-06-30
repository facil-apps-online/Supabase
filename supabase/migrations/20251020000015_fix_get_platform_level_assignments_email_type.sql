DROP FUNCTION IF EXISTS public.get_platform_level_assignments();

CREATE OR REPLACE FUNCTION public.get_platform_level_assignments()
RETURNS TABLE(
  user_id UUID,
  full_name TEXT,
  email TEXT,
  platform_roles JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  SELECT
    u.id,
    (u.raw_user_meta_data->>'first_name') || ' ' || (u.raw_user_meta_data->>'last_name') AS full_name,
    u.email::text,
    '{"app_super_admin": [], "investor": []}'::jsonb AS platform_roles
  FROM auth.users u
  WHERE EXISTS (
    SELECT 1 FROM public.platform_assignments pa JOIN public.roles r ON pa.role_id = r.id WHERE pa.user_id = u.id AND r.name = 'app_super_admin'
  ) OR EXISTS (
    SELECT 1 FROM public.investor_platform_shares ips WHERE ips.user_id = u.id
  );
END;
$$;
