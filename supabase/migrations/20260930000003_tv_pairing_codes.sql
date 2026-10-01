-- Emparejamiento de TVs.
-- tv_displays ahora tiene PK (id, tenant_id, platform_id): una TV sin tenant ya no puede existir ahi, por lo que
-- get_or_create_tv_display / register_tv_display fallaban (23502) y register_tv / authorize_tv_display nunca
-- encontraban fila. Las TVs aun no emparejadas viven en tv_pairing_codes (sin tenant); al registrarlas se
-- promueven a tv_displays conservando el mismo id (la TV guarda ese id en localStorage).

CREATE TABLE IF NOT EXISTS public.tv_pairing_codes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  registration_code text NOT NULL UNIQUE,
  platform_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.tv_pairing_codes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.tv_pairing_codes FROM anon, authenticated;
GRANT ALL ON public.tv_pairing_codes TO service_role;

-- Devuelve la TV (registrada o pendiente) por id o por codigo; crea un codigo nuevo si no se pasa ninguno.
CREATE OR REPLACE FUNCTION public.get_or_create_tv_display(
  p_id uuid DEFAULT NULL::uuid,
  p_registration_code text DEFAULT NULL::text,
  p_platform_id uuid DEFAULT NULL::uuid
) RETURNS TABLE(id uuid, branch_id uuid, registration_code text, is_registered boolean, registered_at timestamptz,
                last_heartbeat timestamptz, media_playlist_id uuid, tenant_id uuid, created_at timestamptz, updated_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $function$
DECLARE
  tv_record public.tv_displays%ROWTYPE;
  pair public.tv_pairing_codes%ROWTYPE;
  generated_code text;
BEGIN
  IF p_id IS NOT NULL THEN
    SELECT * INTO tv_record FROM public.tv_displays WHERE public.tv_displays.id = p_id;
    IF FOUND THEN
      RETURN QUERY SELECT tv_record.id, tv_record.branch_id, tv_record.registration_code, tv_record.is_registered, tv_record.registered_at, tv_record.last_heartbeat, tv_record.media_playlist_id, tv_record.tenant_id, tv_record.created_at, tv_record.updated_at;
      RETURN;
    END IF;
    SELECT * INTO pair FROM public.tv_pairing_codes WHERE public.tv_pairing_codes.id = p_id;
    IF FOUND THEN
      RETURN QUERY SELECT pair.id, NULL::uuid, pair.registration_code, false, NULL::timestamptz, NULL::timestamptz, NULL::uuid, NULL::uuid, pair.created_at, pair.created_at;
      RETURN;
    END IF;
    -- id obsoleto en localStorage: se sigue con el codigo o se crea uno nuevo
  END IF;

  IF p_registration_code IS NOT NULL THEN
    SELECT * INTO tv_record FROM public.tv_displays WHERE public.tv_displays.registration_code = p_registration_code;
    IF FOUND THEN
      RETURN QUERY SELECT tv_record.id, tv_record.branch_id, tv_record.registration_code, tv_record.is_registered, tv_record.registered_at, tv_record.last_heartbeat, tv_record.media_playlist_id, tv_record.tenant_id, tv_record.created_at, tv_record.updated_at;
      RETURN;
    END IF;
    SELECT * INTO pair FROM public.tv_pairing_codes WHERE public.tv_pairing_codes.registration_code = p_registration_code;
    IF FOUND THEN
      RETURN QUERY SELECT pair.id, NULL::uuid, pair.registration_code, false, NULL::timestamptz, NULL::timestamptz, NULL::uuid, NULL::uuid, pair.created_at, pair.created_at;
      RETURN;
    END IF;
    -- codigo desconocido: no se devuelve nada, el cliente redirige.
    RETURN;
  END IF;

  IF p_platform_id IS NULL THEN
    RAISE EXCEPTION 'platform_id es obligatorio para generar un codigo de TV.';
  END IF;

  LOOP
    generated_code := upper(substr(md5(random()::text), 0, 7));
    IF NOT EXISTS (SELECT 1 FROM public.tv_displays d WHERE d.registration_code = generated_code)
       AND NOT EXISTS (SELECT 1 FROM public.tv_pairing_codes c WHERE c.registration_code = generated_code) THEN
      EXIT;
    END IF;
  END LOOP;

  INSERT INTO public.tv_pairing_codes (registration_code, platform_id)
  VALUES (generated_code, p_platform_id)
  RETURNING * INTO pair;

  RETURN QUERY SELECT pair.id, NULL::uuid, pair.registration_code, false, NULL::timestamptz, NULL::timestamptz, NULL::uuid, NULL::uuid, pair.created_at, pair.created_at;
END;
$function$;

-- Paso 1 del dialogo de registro: asegura que el codigo exista (pendiente) y devuelve su id.
CREATE OR REPLACE FUNCTION public.register_tv_display(p_registration_code text, p_platform_id uuid DEFAULT NULL::uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $function$
DECLARE
  v_id uuid;
BEGIN
  SELECT d.id INTO v_id FROM public.tv_displays d WHERE d.registration_code = p_registration_code;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;

  IF p_platform_id IS NULL THEN
    RAISE EXCEPTION 'platform_id es obligatorio para registrar una TV.';
  END IF;

  INSERT INTO public.tv_pairing_codes (registration_code, platform_id)
  VALUES (p_registration_code, p_platform_id)
  ON CONFLICT (registration_code) DO UPDATE SET registration_code = EXCLUDED.registration_code
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$function$;

-- Empareja una TV pendiente (o reasigna sucursal de una ya registrada).
CREATE OR REPLACE FUNCTION public.register_tv(p_registration_code text, p_platform_id uuid, p_branch_id uuid, p_tenant_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $function$
DECLARE
  v_tv_id uuid;
  pair public.tv_pairing_codes%ROWTYPE;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_assignments ua WHERE ua.user_id = auth.uid() AND ua.tenant_id = p_tenant_id AND ua.platform_id = p_platform_id) THEN
    RAISE EXCEPTION 'Acceso denegado: no perteneces a este tenant.';
  END IF;

  UPDATE public.tv_displays
     SET branch_id = p_branch_id, is_registered = true, registered_at = now(), updated_at = now()
   WHERE registration_code = p_registration_code AND tenant_id = p_tenant_id AND platform_id = p_platform_id
  RETURNING id INTO v_tv_id;
  IF v_tv_id IS NOT NULL THEN RETURN v_tv_id; END IF;

  SELECT * INTO pair FROM public.tv_pairing_codes c WHERE c.registration_code = p_registration_code AND c.platform_id = p_platform_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No existe una TV pendiente con el codigo %.', p_registration_code;
  END IF;

  INSERT INTO public.tv_displays (id, registration_code, tenant_id, platform_id, branch_id, is_registered, registered_at)
  VALUES (pair.id, pair.registration_code, p_tenant_id, p_platform_id, p_branch_id, true, now())
  RETURNING id INTO v_tv_id;
  DELETE FROM public.tv_pairing_codes WHERE id = pair.id;
  RETURN v_tv_id;
END;
$function$;

-- Paso 2 del dialogo de registro: autoriza por id (pendiente o ya registrada).
CREATE OR REPLACE FUNCTION public.authorize_tv_display(p_tv_display_id uuid, p_platform_id uuid, p_branch_id uuid, p_tenant_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $function$
DECLARE
  pair public.tv_pairing_codes%ROWTYPE;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_assignments ua WHERE ua.user_id = auth.uid() AND ua.tenant_id = p_tenant_id AND ua.platform_id = p_platform_id) THEN
    RAISE EXCEPTION 'Acceso denegado: no perteneces a este tenant.';
  END IF;

  UPDATE public.tv_displays
     SET branch_id = p_branch_id, is_registered = true, registered_at = now(), updated_at = now()
   WHERE id = p_tv_display_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;
  IF FOUND THEN RETURN; END IF;

  SELECT * INTO pair FROM public.tv_pairing_codes c WHERE c.id = p_tv_display_id AND c.platform_id = p_platform_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'TV no encontrada.';
  END IF;

  INSERT INTO public.tv_displays (id, registration_code, tenant_id, platform_id, branch_id, is_registered, registered_at)
  VALUES (pair.id, pair.registration_code, p_tenant_id, p_platform_id, p_branch_id, true, now());
  DELETE FROM public.tv_pairing_codes WHERE id = pair.id;
END;
$function$;
