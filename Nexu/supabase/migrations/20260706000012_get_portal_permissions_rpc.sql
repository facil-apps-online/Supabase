-- RPC for portal employees to read their portal permissions
-- Uses SECURITY DEFINER to bypass RLS (portal employees have no profiles entry
-- so get_user_tenant_id() returns NULL for them)
CREATE OR REPLACE FUNCTION public.get_portal_permissions(p_tenant_id UUID)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_settings JSONB;
BEGIN
  SELECT settings_data INTO v_settings
  FROM public.tenant_settings
  WHERE tenant_id = p_tenant_id
    AND setting_key = 'portal'
  LIMIT 1;

  RETURN jsonb_build_object(
    'can_change_photo', COALESCE((v_settings->>'can_change_photo')::boolean, true),
    'can_change_data',  COALESCE((v_settings->>'can_change_data')::boolean, true)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_portal_permissions(UUID) TO anon, authenticated;
