-- Migration: update_uom_rpcs_platform_id
-- Created at: 2026-03-01 00:00:01

-- 1. get_units_of_measure
DROP FUNCTION IF EXISTS public.get_units_of_measure(uuid);
CREATE OR REPLACE FUNCTION public.get_units_of_measure(p_platform_id uuid, p_tenant_id uuid)
 RETURNS TABLE(id uuid, tenant_id uuid, name text, abbreviation text, created_at timestamp with time zone, is_global boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
    RETURN QUERY SELECT uom.id, uom.tenant_id, uom.name, uom.abbreviation, uom.created_at, (uom.tenant_id IS NULL) AS is_global
    FROM public.units_of_measure uom
    WHERE (uom.tenant_id = p_tenant_id OR uom.tenant_id IS NULL)
      AND uom.platform_id = p_platform_id
    ORDER BY uom.name;
END;
$function$;

-- 2. create_unit_of_measure
DROP FUNCTION IF EXISTS public.create_unit_of_measure(uuid, text, text);
CREATE OR REPLACE FUNCTION public.create_unit_of_measure(p_platform_id uuid, p_tenant_id uuid, p_name text, p_abbreviation text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    new_id UUID;
BEGIN
    INSERT INTO public.units_of_measure (platform_id, tenant_id, name, abbreviation)
    VALUES (p_platform_id, p_tenant_id, p_name, p_abbreviation)
    RETURNING id INTO new_id;
    RETURN new_id;
END;
$function$;

-- 3. update_unit_of_measure
DROP FUNCTION IF EXISTS public.update_unit_of_measure(uuid, uuid, text, text);
CREATE OR REPLACE FUNCTION public.update_unit_of_measure(p_id uuid, p_platform_id uuid, p_tenant_id uuid, p_name text, p_abbreviation text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
    UPDATE public.units_of_measure
    SET name = p_name, abbreviation = p_abbreviation
    WHERE id = p_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;
END;
$function$;

-- 4. delete_unit_of_measure
DROP FUNCTION IF EXISTS public.delete_unit_of_measure(uuid, uuid);
CREATE OR REPLACE FUNCTION public.delete_unit_of_measure(p_id uuid, p_platform_id uuid, p_tenant_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
    DELETE FROM public.units_of_measure
    WHERE id = p_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;
END;
$function$;
