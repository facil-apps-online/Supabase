-- Migration: expone si un usuario está revocado (auth.users.banned_until), para poder
-- mostrar "Revocado" en Mi Equipo y ofrecer el botón de reactivar.

DROP FUNCTION IF EXISTS public.get_platform_level_assignments();

CREATE OR REPLACE FUNCTION public.get_platform_level_assignments()
RETURNS TABLE(
    user_id uuid,
    full_name text,
    first_name text,
    last_name text,
    email text,
    is_pending boolean,
    is_revoked boolean,
    platform_roles jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  SELECT
    u.id AS user_id,
    (u.raw_user_meta_data->>'first_name') || ' ' || (u.raw_user_meta_data->>'last_name') AS full_name,
    u.raw_user_meta_data->>'first_name' AS first_name,
    u.raw_user_meta_data->>'last_name' AS last_name,
    u.email::text,
    COALESCE((u.raw_user_meta_data->>'invitation_pending')::boolean, false) AS is_pending,
    (u.banned_until IS NOT NULL AND u.banned_until > now()) AS is_revoked,
    jsonb_build_object(
      'app_super_admin', (
        SELECT COALESCE(jsonb_agg(jsonb_build_object('platform_id', pa.platform_id, 'platform_name', p.name)), '[]'::jsonb)
        FROM public.platform_assignments pa
        JOIN public.roles r ON pa.role_id = r.id
        JOIN public.platforms p ON pa.platform_id = p.id
        WHERE r.name = 'app_super_admin' AND pa.user_id = u.id
      ),
      'comercial_admin', (
        SELECT COALESCE(jsonb_agg(jsonb_build_object('platform_id', pa.platform_id, 'platform_name', p.name)), '[]'::jsonb)
        FROM public.platform_assignments pa
        JOIN public.roles r ON pa.role_id = r.id
        JOIN public.platforms p ON pa.platform_id = p.id
        WHERE r.name = 'comercial_admin' AND pa.user_id = u.id
      ),
      'investor', (
        SELECT COALESCE(jsonb_agg(jsonb_build_object('platform_id', ips.platform_id, 'platform_name', p.name, 'stake_percentage', ips.investment_share * 100)), '[]'::jsonb)
        FROM public.investor_platform_shares ips
        JOIN public.platforms p ON ips.platform_id = p.id
        WHERE ips.user_id = u.id
      ),
      'vendor', (
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'id', vpc.id,
            'platform_id', vpc.platform_id,
            'platform_name', p.name,
            'first_payment_commission_rate', vpc.first_payment_commission_rate,
            'recurring_payment_commission_rate', vpc.recurring_payment_commission_rate
        )), '[]'::jsonb)
        FROM public.vendor_platform_commissions vpc
        JOIN public.platforms p ON vpc.platform_id = p.id
        WHERE vpc.user_id = u.id
      )
    ) AS platform_roles
  FROM auth.users u
  WHERE u.email !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}_';
END;
$$;
