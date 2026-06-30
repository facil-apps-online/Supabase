-- Migration to consolidate and fix all create_branch and update_branch function overloads.

BEGIN;

-- Step 1: Drop all known conflicting function signatures for create_branch
DROP FUNCTION IF EXISTS public.create_branch(text, text, text, text, text, text, text, text, text, text, text, numeric, numeric, text);
DROP FUNCTION IF EXISTS public.create_branch(uuid, text, text, text, text, text, text, text, text, text, text, text, numeric, numeric, text);
DROP FUNCTION IF EXISTS public.create_branch(uuid, text, text, text, text, text, text, text, text, text, text, text, numeric, numeric, text, text);
DROP FUNCTION IF EXISTS public.create_branch(uuid, text, text, text);
DROP FUNCTION IF EXISTS public.create_branch(uuid, text, text, text, text, text, text, text, text, text, text, text, numeric, numeric, text, text, text); -- My own previously attempted signature

-- Step 2: Drop all known conflicting function signatures for update_branch
DROP FUNCTION IF EXISTS public.update_branch(uuid, text, text, text, text, text, text, text, text, text, text, text, numeric, numeric, text, text);
DROP FUNCTION IF EXISTS public.update_branch(uuid, uuid, text, text, text, text, text, text, text, text, text, text, text, text, numeric, numeric, text, text); -- My own previously attempted signature
DROP FUNCTION IF EXISTS public.update_branch(uuid, uuid, text, text, text, text, text, text, text, text, text, text, text, text, numeric, numeric);
DROP FUNCTION IF EXISTS public.update_branch(uuid, uuid, text, text, text, text, text, text, text, text, text, text, text, numeric, numeric);

-- Step 3: Create a single, comprehensive, and idempotent create_branch function
CREATE OR REPLACE FUNCTION public.create_branch(
    p_tenant_id uuid,
    p_name text,
    p_address text DEFAULT NULL,
    p_description text DEFAULT NULL,
    p_contact_phone text DEFAULT NULL,
    p_whatsapp_phone text DEFAULT NULL,
    p_commercial_email text DEFAULT NULL,
    p_website text DEFAULT NULL,
    p_physical_address_line1 text DEFAULT NULL,
    p_physical_address_line2 text DEFAULT NULL,
    p_physical_city text DEFAULT NULL,
    p_physical_state text DEFAULT NULL,
    p_physical_postal_code text DEFAULT NULL,
    p_latitude numeric DEFAULT NULL,
    p_longitude numeric DEFAULT NULL,
    p_timezone text DEFAULT NULL,
    p_google_place_id text DEFAULT NULL
)
RETURNS public.branches
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    new_branch public.branches;
BEGIN
    INSERT INTO public.branches (
        tenant_id, name, address, description, contact_phone, whatsapp_phone, commercial_email,
        website, physical_address_line1, physical_address_line2, physical_city, physical_state,
        physical_postal_code, latitude, longitude, timezone, is_main_branch, google_place_id
    )
    VALUES (
        p_tenant_id, p_name, p_address, p_description, p_contact_phone, p_whatsapp_phone, p_commercial_email,
        p_website, p_physical_address_line1, p_physical_address_line2, p_physical_city, p_physical_state,
        p_physical_postal_code, p_latitude, p_longitude, p_timezone, false, p_google_place_id
    )
    RETURNING * INTO new_branch;
    RETURN new_branch;
END;
$$;

-- Step 4: Create a single, comprehensive, and idempotent update_branch function
CREATE OR REPLACE FUNCTION public.update_branch(
    p_branch_id uuid,
    p_tenant_id uuid,
    p_name text DEFAULT NULL,
    p_description text DEFAULT NULL,
    p_address text DEFAULT NULL,
    p_contact_phone text DEFAULT NULL,
    p_whatsapp_phone text DEFAULT NULL,
    p_commercial_email text DEFAULT NULL,
    p_website text DEFAULT NULL,
    p_physical_address_line1 text DEFAULT NULL,
    p_physical_address_line2 text DEFAULT NULL,
    p_physical_city text DEFAULT NULL,
    p_physical_state text DEFAULT NULL,
    p_physical_postal_code text DEFAULT NULL,
    p_latitude numeric DEFAULT NULL,
    p_longitude numeric DEFAULT NULL,
    p_timezone text DEFAULT NULL,
    p_google_place_id text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    UPDATE public.branches
    SET
        name = COALESCE(p_name, name),
        description = COALESCE(p_description, description),
        address = COALESCE(p_address, address),
        contact_phone = COALESCE(p_contact_phone, contact_phone),
        whatsapp_phone = COALESCE(p_whatsapp_phone, whatsapp_phone),
        commercial_email = COALESCE(p_commercial_email, commercial_email),
        website = COALESCE(p_website, website),
        physical_address_line1 = COALESCE(p_physical_address_line1, physical_address_line1),
        physical_address_line2 = COALESCE(p_physical_address_line2, physical_address_line2),
        physical_city = COALESCE(p_physical_city, physical_city),
        physical_state = COALESCE(p_physical_state, physical_state),
        physical_postal_code = COALESCE(p_physical_postal_code, physical_postal_code),
        latitude = COALESCE(p_latitude, latitude),
        longitude = COALESCE(p_longitude, longitude),
        timezone = COALESCE(p_timezone, timezone),
        google_place_id = COALESCE(p_google_place_id, google_place_id),
        updated_at = now()
    WHERE id = p_branch_id AND tenant_id = p_tenant_id;
END;
$$;

COMMIT;
