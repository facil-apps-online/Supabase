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
  WITH all_users AS (
    SELECT id, raw_user_meta_data, email FROM auth.users
  ),
  app_super_admins AS (
    SELECT
      pa.user_id,
      jsonb_agg(jsonb_build_object('platform_id', pa.platform_id, 'platform_name', p.name)) AS app_super_admin_platforms
    FROM public.platform_assignments pa
    JOIN public.roles r ON pa.role_id = r.id
    JOIN public.platforms p ON pa.platform_id = p.id
    WHERE r.name = 'app_super_admin'
    GROUP BY pa.user_id
  ),
  investors AS (
    SELECT
      ips.user_id,
      jsonb_agg(jsonb_build_object('platform_id', ips.platform_id, 'platform_name', p.name, 'stake_percentage', ips.investment_share * 100)) AS investor_platforms
    FROM public.investor_platform_shares ips
    JOIN public.platforms p ON ips.platform_id = p.id
    GROUP BY ips.user_id
  )
  SELECT
    u.id,
    (u.raw_user_meta_data->>'first_name') || ' ' || (u.raw_user_meta_data->>'last_name') AS full_name,
    u.email,
    jsonb_build_object(
      'app_super_admin', COALESCE(asa.app_super_admin_platforms, '[]'::jsonb),
      'investor', COALESCE(i.investor_platforms, '[]'::jsonb)
    ) AS platform_roles
  FROM all_users u
  LEFT JOIN app_super_admins asa ON u.id = asa.user_id
  LEFT JOIN investors i ON u.id = i.user_id
  WHERE asa.user_id IS NOT NULL OR i.user_id IS NOT NULL;
END;
$$;
