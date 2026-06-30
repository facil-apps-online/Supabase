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
      u.id AS user_id,
      u.raw_user_meta_data->>'full_name' AS full_name,
      u.email,
      '{}'::jsonb AS platform_roles
  FROM auth.users u;
END;
$$;
