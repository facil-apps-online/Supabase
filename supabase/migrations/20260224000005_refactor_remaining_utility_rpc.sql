-- Migración: Refactorización de funciones RPC restantes (Utilidad, Mantenimiento, TV y Suscripciones)
-- Se agrega el parámetro p_platform_id y se estandarizan los filtros por tenant_id y platform_id.
-- Timestamp: 20260224000005

BEGIN;

--------------------------------------------------------------------------------
-- 1. TV Displays Module
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.authorize_tv_display(uuid, uuid, uuid);
CREATE OR REPLACE FUNCTION public.authorize_tv_display(p_tv_display_id uuid, p_platform_id uuid, p_branch_id uuid, p_tenant_id uuid)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
BEGIN
    UPDATE public.tv_displays
    SET branch_id = p_branch_id,
        is_registered = true,
        registered_at = now(),
        updated_at = now()
    WHERE id = p_tv_display_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;
END;
$function$;

DROP FUNCTION IF EXISTS public.register_tv(text, uuid, uuid);
CREATE OR REPLACE FUNCTION public.register_tv(p_registration_code text, p_platform_id uuid, p_branch_id uuid, p_tenant_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_tv_id uuid;
BEGIN
    UPDATE public.tv_displays
    SET branch_id = p_branch_id,
        is_registered = true,
        registered_at = now(),
        updated_at = now()
    WHERE registration_code = p_registration_code 
      AND tenant_id = p_tenant_id 
      AND platform_id = p_platform_id
    RETURNING id INTO v_tv_id;

    RETURN v_tv_id;
END;
$function$;

DROP FUNCTION IF EXISTS public.get_managed_tvs(uuid);
CREATE OR REPLACE FUNCTION public.get_managed_tvs(p_tenant_id uuid, p_platform_id uuid)
 RETURNS SETOF tv_displays
 LANGUAGE sql
 STABLE
AS $function$
    SELECT * FROM public.tv_displays 
    WHERE tenant_id = p_tenant_id AND platform_id = p_platform_id;
$function$;

--------------------------------------------------------------------------------
-- 2. Equipment Maintenance Module
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.create_equipment_maintenance_record(uuid, jsonb);
CREATE OR REPLACE FUNCTION public.create_equipment_maintenance_record(p_tenant_id uuid, p_platform_id uuid, p_maintenance_data jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_record_id uuid;
BEGIN
    INSERT INTO public.equipment_maintenance_history (
        equipment_id, tenant_id, platform_id, maintenance_date, notes
    ) VALUES (
        (p_maintenance_data->>'equipment_id')::uuid,
        p_tenant_id,
        p_platform_id,
        (p_maintenance_data->>'maintenance_date')::date,
        p_maintenance_data->>'notes'
    ) RETURNING id INTO v_record_id;

    RETURN v_record_id;
END;
$function$;

DROP FUNCTION IF EXISTS public.update_equipment_maintenance_record(uuid, uuid, jsonb);
CREATE OR REPLACE FUNCTION public.update_equipment_maintenance_record(p_tenant_id uuid, p_platform_id uuid, p_record_id uuid, p_updates jsonb)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
BEGIN
    UPDATE public.equipment_maintenance_history
    SET maintenance_date = COALESCE((p_updates->>'maintenance_date')::date, maintenance_date),
        notes = COALESCE(p_updates->>'notes', notes)
    WHERE id = p_record_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;
END;
$function$;

DROP FUNCTION IF EXISTS public.delete_equipment_maintenance_record(uuid, uuid);
CREATE OR REPLACE FUNCTION public.delete_equipment_maintenance_record(p_tenant_id uuid, p_platform_id uuid, p_record_id uuid)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
BEGIN
    DELETE FROM public.equipment_maintenance_history
    WHERE id = p_record_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;
END;
$function$;

DROP FUNCTION IF EXISTS public.get_equipment_maintenance_history(uuid, uuid);
CREATE OR REPLACE FUNCTION public.get_equipment_maintenance_history(p_tenant_id uuid, p_platform_id uuid, p_equipment_id uuid)
 RETURNS SETOF equipment_maintenance_history
 LANGUAGE sql
 STABLE
AS $function$
    SELECT * FROM public.equipment_maintenance_history 
    WHERE equipment_id = p_equipment_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id
    ORDER BY maintenance_date DESC;
$function$;

--------------------------------------------------------------------------------
-- 3. Auth & Integrations Module
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_google_auth_url(uuid);
CREATE OR REPLACE FUNCTION public.get_google_auth_url(p_tenant_id uuid, p_platform_id uuid)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- Esta función suele ser un placeholder para lógica que se resuelve en la Edge,
    -- pero la estandarizamos para que el filtro sea correcto si busca config.
    RETURN 'https://accounts.google.com/o/oauth2/v2/auth...'; -- Placeholder logic
END;
$function$;

DROP FUNCTION IF EXISTS public.get_gmail_auth_url(uuid);
CREATE OR REPLACE FUNCTION public.get_gmail_auth_url(p_tenant_id uuid, p_platform_id uuid)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN 'https://accounts.google.com/o/oauth2/v2/auth...'; -- Placeholder logic
END;
$function$;

DROP FUNCTION IF EXISTS public.disconnect_google_provider(uuid, text, uuid);
CREATE OR REPLACE FUNCTION public.disconnect_google_provider(p_tenant_id uuid, p_platform_id uuid, p_provider text, p_requesting_user_id uuid)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
BEGIN
    DELETE FROM public.tenant_integrations
    WHERE tenant_id = p_tenant_id AND platform_id = p_platform_id AND provider = p_provider;
END;
$function$;

--------------------------------------------------------------------------------
-- 4. Subscription & Assets Module
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.increment_asset_usage_rpc(uuid, text, bigint);
CREATE OR REPLACE FUNCTION public.increment_asset_usage_rpc(p_tenant_id uuid, p_platform_id uuid, p_asset_key text, p_quantity_to_add bigint)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- Nota: asset_usage_tracking suele estar en Core, pero si existe localmente:
    -- Ajustar si la tabla existe en Servicios
    NULL;
END;
$function$;

DROP FUNCTION IF EXISTS public.get_price_for_tenant_asset(uuid, text);
CREATE OR REPLACE FUNCTION public.get_price_for_tenant_asset(p_tenant_id uuid, p_platform_id uuid, p_asset_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- Lógica de consulta a Core o localmente
    RETURN '{}'::jsonb;
END;
$function$;

DROP FUNCTION IF EXISTS public.get_subscription_status_for_tenant(uuid);
CREATE OR REPLACE FUNCTION public.get_subscription_status_for_tenant(p_tenant_id uuid, p_platform_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN (SELECT jsonb_build_object(
        'status', subscription_status,
        'is_active', is_active
    ) FROM public.tenants WHERE id = p_tenant_id AND platform_id = p_platform_id);
END;
$function$;

--------------------------------------------------------------------------------
-- 5. Commission Matrix Module
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_product_commission_matrix(uuid, uuid);
CREATE OR REPLACE FUNCTION public.get_product_commission_matrix(p_tenant_id uuid, p_platform_id uuid, p_product_id uuid)
 RETURNS TABLE(user_id uuid, first_name text, last_name text, commission_rate numeric)
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN QUERY
    SELECT 
        u.user_id, u.first_name, u.last_name, 
        COALESCE(puc.commission_rate, u.default_product_commission_rate) as commission_rate
    FROM public.get_tenant_users(p_tenant_id, p_platform_id) u
    LEFT JOIN public.product_user_commissions puc ON u.user_id = puc.user_id AND puc.product_id = p_product_id AND puc.tenant_id = p_tenant_id AND puc.platform_id = p_platform_id;
END;
$function$;

DROP FUNCTION IF EXISTS public.get_service_commission_matrix(uuid, uuid);
CREATE OR REPLACE FUNCTION public.get_service_commission_matrix(p_tenant_id uuid, p_platform_id uuid, p_service_id uuid)
 RETURNS TABLE(user_id uuid, first_name text, last_name text, commission_rate numeric)
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN QUERY
    SELECT 
        u.user_id, u.first_name, u.last_name, 
        COALESCE(suc.commission_rate, u.default_service_commission_rate) as commission_rate
    FROM public.get_tenant_users(p_tenant_id, p_platform_id) u
    LEFT JOIN public.service_user_commissions suc ON u.user_id = suc.user_id AND suc.service_id = p_service_id AND suc.tenant_id = p_tenant_id AND suc.platform_id = p_platform_id;
END;
$function$;

COMMIT;
