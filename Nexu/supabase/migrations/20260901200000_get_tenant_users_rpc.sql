-- =============================================================
-- get_tenant_users: usuarios del tenant enriquecidos con la
-- metadata de auth.users (fuente de verdad del perfil).
-- first_name/last_name/email/phone/avatar_url salen de profiles
-- y si estan vacios se resuelven desde raw_user_meta_data.
-- Evita dobles escrituras: la metadata es la fuente, la lista
-- de usuarios la lee desde aqui.
-- =============================================================
CREATE OR REPLACE FUNCTION public.get_tenant_users(p_tenant_id UUID)
RETURNS TABLE (
    id UUID,
    user_id UUID,
    tenant_id UUID,
    first_name TEXT,
    last_name TEXT,
    email TEXT,
    phone TEXT,
    avatar_url TEXT,
    is_super_admin BOOLEAN,
    active BOOLEAN,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    -- Autorizacion: solo super admins o miembros del tenant consultado
    IF NOT (
        public.is_super_admin(auth.uid())
        OR public.get_user_tenant_id(auth.uid()) = p_tenant_id
    ) THEN
        RAISE EXCEPTION 'No autorizado para consultar los usuarios de este tenant.';
    END IF;
    RETURN QUERY
    SELECT
        p.id,
        p.user_id,
        p.tenant_id,
        COALESCE(NULLIF(p.first_name, ''), au.raw_user_meta_data->>'first_name') AS first_name,
        COALESCE(NULLIF(p.last_name, ''), au.raw_user_meta_data->>'last_name') AS last_name,
        COALESCE(NULLIF(p.email, ''), au.raw_user_meta_data->>'real_email', au.email) AS email,
        COALESCE(NULLIF(p.phone, ''), au.raw_user_meta_data->>'phone') AS phone,
        COALESCE(NULLIF(p.avatar_url, ''), au.raw_user_meta_data->>'avatar_url') AS avatar_url,
        p.is_super_admin,
        p.active,
        p.created_at,
        p.updated_at
    FROM public.profiles p
    JOIN auth.users au ON au.id = p.user_id
    WHERE p.tenant_id = p_tenant_id;
END;
$$;
-- Exposicion restringida: solo usuarios autenticados
REVOKE EXECUTE ON FUNCTION public.get_tenant_users(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_tenant_users(UUID) TO authenticated;
