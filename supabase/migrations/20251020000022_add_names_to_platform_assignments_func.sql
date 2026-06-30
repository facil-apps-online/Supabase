DROP FUNCTION IF EXISTS public.get_platform_level_assignments();

CREATE OR REPLACE FUNCTION public.get_platform_level_assignments()
RETURNS TABLE(
  user_id UUID,
  full_name TEXT,
  first_name TEXT,
  last_name TEXT,
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
    u.raw_user_meta_data->>'first_name' AS first_name,
    u.raw_user_meta_data->>'last_name' AS last_name,
    u.email::text,
    jsonb_build_object(
      'app_super_admin', (
        SELECT COALESCE(jsonb_agg(jsonb_build_object('platform_id', pa.platform_id, 'platform_name', p.name)), '[]'::jsonb)
        FROM public.platform_assignments pa
        JOIN public.roles r ON pa.role_id = r.id
        JOIN public.platforms p ON pa.platform_id = p.id
        WHERE r.name = 'app_super_admin' AND pa.user_id = u.id
      ),
      'investor', (
        SELECT COALESCE(jsonb_agg(jsonb_build_object('platform_id', ips.platform_id, 'platform_name', p.name, 'stake_percentage', ips.investment_share * 100)), '[]'::jsonb)
        FROM public.investor_platform_shares ips
        JOIN public.platforms p ON ips.platform_id = p.id
        WHERE ips.user_id = u.id
      ),
      'super_admin', (
        SELECT CASE WHEN EXISTS (
            SELECT 1 FROM public.user_assignments ua JOIN public.roles r ON ua.role_id = r.id WHERE ua.user_id = u.id AND r.name = 'super_admin'
        ) THEN 'true'::jsonb ELSE 'false'::jsonb END
      )
    ) AS platform_roles
  FROM auth.users u
  WHERE u.email !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}_';
END;
$$;