
CREATE OR REPLACE FUNCTION public.get_platform_level_assignments()
RETURNS TABLE(
  user_id UUID,
  full_name TEXT,
  email TEXT,
  platform_roles JSONB
)
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN QUERY
  WITH user_platform_roles AS (
    -- App Super Admins from metadata
    SELECT
      u.id AS user_id,
      u.raw_user_meta_data->>'full_name' AS full_name,
      u.email,
      jsonb_agg(
        jsonb_build_object(
          'platform_id', (assignment->>'platform_id')::UUID,
          'platform_name', p.name
        )
      ) FILTER (WHERE assignment->>'role' = 'app_super_admin') AS app_super_admin_platforms,
      NULL::jsonb AS investor_platforms
    FROM auth.users u
    CROSS JOIN jsonb_array_elements(u.raw_app_meta_data->'assignments') AS assignment
    LEFT JOIN public.platforms p ON (assignment->>'platform_id')::UUID = p.id
    WHERE u.raw_app_meta_data->'assignments' IS NOT NULL
    GROUP BY u.id

    UNION ALL

    -- Investors from dedicated table
    SELECT
      u.id AS user_id,
      u.raw_user_meta_data->>'full_name' AS full_name,
      u.email,
      NULL::jsonb AS app_super_admin_platforms,
      jsonb_agg(
        jsonb_build_object(
          'platform_id', s.platform_id,
          'platform_name', p.name,
          'stake_percentage', s.investment_share * 100
        )
      ) AS investor_platforms
    FROM auth.users u
    JOIN public.investor_platform_shares s ON u.id = s.user_id
    LEFT JOIN public.platforms p ON s.platform_id = p.id
    GROUP BY u.id
  )
  SELECT
    upr.user_id,
    upr.full_name,
    upr.email,
    jsonb_build_object(
      'app_super_admin', COALESCE(jsonb_agg(upr.app_super_admin_platforms) FILTER (WHERE upr.app_super_admin_platforms IS NOT NULL), '[]'::jsonb),
      'investor', COALESCE(jsonb_agg(upr.investor_platforms) FILTER (WHERE upr.investor_platforms IS NOT NULL), '[]'::jsonb)
    ) AS platform_roles
  FROM user_platform_roles upr
  GROUP BY upr.user_id, upr.full_name, upr.email;
END;
$$;
