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
  WITH user_roles AS (
      -- App Super Admins
      SELECT
          u.id AS user_id,
          'app_super_admin' AS role_type,
          jsonb_agg(
              jsonb_build_object(
                  'platform_id', (a->>'platform_id')::UUID,
                  'platform_name', p.name
              )
          ) AS roles
      FROM auth.users u
      CROSS JOIN jsonb_array_elements(u.raw_app_meta_data->'assignments') AS a
      LEFT JOIN platforms p ON (a->>'platform_id')::UUID = p.id
      WHERE a->>'role' = 'app_super_admin'
      GROUP BY u.id

      UNION ALL

      -- Investors
      SELECT
          u.id AS user_id,
          'investor' AS role_type,
          jsonb_agg(
              jsonb_build_object(
                  'platform_id', s.platform_id,
                  'platform_name', p.name,
                  'stake_percentage', s.investment_share * 100
              )
          ) AS roles
      FROM auth.users u
      JOIN investor_platform_shares s ON u.id = s.user_id
      LEFT JOIN platforms p ON s.platform_id = p.id
      GROUP BY u.id
  )
  SELECT
      u.id AS user_id,
      (u.raw_user_meta_data->>'first_name') || ' ' || (u.raw_user_meta_data->>'last_name') AS full_name,
      u.email,
      jsonb_object_agg(
          ur.role_type,
          ur.roles
      ) FILTER (WHERE ur.role_type IS NOT NULL) AS platform_roles
  FROM auth.users u
  LEFT JOIN user_roles ur ON u.id = ur.user_id
  WHERE ur.user_id IS NOT NULL
  GROUP BY u.id;
END;
$$;
