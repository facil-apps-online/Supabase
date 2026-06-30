
-- Eliminar versión anterior de la función
DROP FUNCTION IF EXISTS public.create_branch(uuid, text, text, text, text, text, text, text, text, text, text, text, text, numeric, numeric, text, text);

-- Crear función actualizada con p_platform_id
CREATE OR REPLACE FUNCTION public.create_branch(
    p_tenant_id uuid, 
    p_name text, 
    p_platform_id uuid,
    p_address text DEFAULT NULL::text, 
    p_description text DEFAULT NULL::text, 
    p_contact_phone text DEFAULT NULL::text, 
    p_whatsapp_phone text DEFAULT NULL::text, 
    p_commercial_email text DEFAULT NULL::text, 
    p_website text DEFAULT NULL::text, 
    p_physical_address_line1 text DEFAULT NULL::text, 
    p_physical_address_line2 text DEFAULT NULL::text, 
    p_physical_city text DEFAULT NULL::text, 
    p_physical_state text DEFAULT NULL::text, 
    p_physical_postal_code text DEFAULT NULL::text, 
    p_latitude numeric DEFAULT NULL::numeric, 
    p_longitude numeric DEFAULT NULL::numeric, 
    p_timezone text DEFAULT NULL::text, 
    p_google_place_id text DEFAULT NULL::text
)
 RETURNS branches
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    new_branch public.branches;
BEGIN
    INSERT INTO public.branches (
        tenant_id, 
        name, 
        platform_id,
        address, 
        description, 
        contact_phone, 
        whatsapp_phone, 
        commercial_email,
        website, 
        physical_address_line1, 
        physical_address_line2, 
        physical_city, 
        physical_state,
        physical_postal_code, 
        latitude, 
        longitude, 
        timezone, 
        is_main_branch, 
        google_place_id
    )
    VALUES (
        p_tenant_id, 
        p_name, 
        p_platform_id,
        p_address, 
        p_description, 
        p_contact_phone, 
        p_whatsapp_phone, 
        p_commercial_email,
        p_website, 
        p_physical_address_line1, 
        p_physical_address_line2, 
        p_physical_city, 
        p_physical_state,
        p_physical_postal_code, 
        p_latitude, 
        p_longitude, 
        p_timezone, 
        false, 
        p_google_place_id
    )
    RETURNING * INTO new_branch;
    RETURN new_branch;
END;
$function$;
