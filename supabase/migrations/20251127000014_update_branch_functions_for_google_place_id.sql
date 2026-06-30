-- This migration only handles the CREATE_BRANCH function overloads.
-- It uses DROP + CREATE to avoid signature change errors.

-- Overload 1 (from user: p_tenant_id, p_name, p_address, p_contact_phone, ... p_timezone) - Returns SETOF
DROP FUNCTION IF EXISTS public.create_branch(uuid, text, text, text, text, text, text, text, text, text, text, text, numeric, numeric, text);
CREATE FUNCTION public.create_branch(
    p_tenant_id uuid, p_name text, p_address text, p_contact_phone text, p_whatsapp_phone text, p_commercial_email text, p_website text, 
    p_physical_address_line1 text, p_physical_address_line2 text, p_physical_city text, p_physical_state text, p_physical_postal_code text, 
    p_latitude numeric, p_longitude numeric, p_timezone text, p_google_place_id text
)
RETURNS SETOF public.branches LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY
    INSERT INTO public.branches (
        tenant_id, name, address, contact_phone, whatsapp_phone, commercial_email, website,
        physical_address_line1, physical_address_line2, physical_city, physical_state,
        physical_postal_code, latitude, longitude, timezone, google_place_id
    )
    VALUES (
        p_tenant_id, p_name, p_address, p_contact_phone, p_whatsapp_phone, p_commercial_email, p_website,
        p_physical_address_line1, p_physical_address_line2, p_physical_city, p_physical_state,
        p_physical_postal_code, p_latitude, p_longitude, p_timezone, p_google_place_id
    )
    RETURNING *;
END;
$$;

-- Overload 2 (from user: p_tenant_id, p_name, p_address) - Returns single record
DROP FUNCTION IF EXISTS public.create_branch(uuid, text, text);
CREATE FUNCTION public.create_branch(
    p_tenant_id uuid, p_name text, p_address text, p_google_place_id text
)
RETURNS public.branches LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    new_branch public.branches;
BEGIN
    INSERT INTO public.branches (tenant_id, name, address, is_main_branch, google_place_id)
    VALUES (p_tenant_id, p_name, p_address, false, p_google_place_id)
    RETURNING * INTO new_branch;
    RETURN new_branch;
END;
$$;

-- Overload 3 (from user: p_tenant_id, p_name, p_address, p_contact_phone, ...) - Returns single record
DROP FUNCTION IF EXISTS public.create_branch(uuid, text, text, text, text, text, text, text, text, text, text, text, numeric, numeric);
CREATE FUNCTION public.create_branch(
    p_tenant_id uuid, p_name text, p_address text, p_contact_phone text, p_whatsapp_phone text, p_commercial_email text, p_website text,
    p_physical_address_line1 text, p_physical_address_line2 text, p_physical_city text, p_physical_state text, p_physical_postal_code text,
    p_latitude numeric, p_longitude numeric, p_google_place_id text
)
RETURNS public.branches LANGUAGE plpgsql AS $$
DECLARE
    new_branch public.branches;
BEGIN
    INSERT INTO public.branches (
        tenant_id, name, address, is_main_branch, contact_phone, whatsapp_phone, commercial_email,
        website, physical_address_line1, physical_address_line2, physical_city, physical_state,
        physical_postal_code, latitude, longitude, google_place_id
    )
    VALUES (
        p_tenant_id, p_name, p_address, false, p_contact_phone, p_whatsapp_phone, p_commercial_email,
        p_website, p_physical_address_line1, p_physical_address_line2, p_physical_city, p_physical_state,
        p_physical_postal_code, p_latitude, p_longitude, p_google_place_id
    )
    RETURNING * INTO new_branch;
    RETURN new_branch;
END;
$$;

-- Overload 4 (from user: p_name, p_address, p_contact_phone, ...) - Returns single record
DROP FUNCTION IF EXISTS public.create_branch(text, text, text, text, text, text, text, text, text, text, text, numeric, numeric);
CREATE FUNCTION public.create_branch(
    p_name text, p_address text, p_contact_phone text, p_whatsapp_phone text, p_commercial_email text, p_website text,
    p_physical_address_line1 text, p_physical_address_line2 text, p_physical_city text, p_physical_state text, p_physical_postal_code text,
    p_latitude numeric, p_longitude numeric, p_google_place_id text
)
RETURNS public.branches LANGUAGE plpgsql AS $$
DECLARE
    v_tenant_id UUID := (auth.jwt() -> 'app_metadata' ->> 'tenant_id')::uuid;
    new_branch public.branches;
BEGIN
    IF v_tenant_id IS NULL THEN RAISE EXCEPTION 'Tenant ID not found in JWT claims'; END IF;
    INSERT INTO public.branches (
        tenant_id, name, address, is_main_branch, contact_phone, whatsapp_phone, commercial_email,
        website, physical_address_line1, physical_address_line2, physical_city, physical_state,
        physical_postal_code, latitude, longitude, google_place_id
    )
    VALUES (
        v_tenant_id, p_name, p_address, false, p_contact_phone, p_whatsapp_phone, p_commercial_email,
        p_website, p_physical_address_line1, p_physical_address_line2, p_physical_city, p_physical_state,
        p_physical_postal_code, p_latitude, p_longitude, p_google_place_id
    )
    RETURNING * INTO new_branch;
    RETURN new_branch;
END;
$$;