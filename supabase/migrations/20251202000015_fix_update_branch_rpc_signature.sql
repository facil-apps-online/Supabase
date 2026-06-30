-- Migration to fix the function signature for update_branch
-- This adds the p_tenant_id parameter and the corresponding security check in the WHERE clause.

CREATE OR REPLACE FUNCTION public.update_branch(
    p_branch_id uuid,
    p_tenant_id uuid, -- Tenant ID for security
    p_name text,
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
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    UPDATE public.branches
    SET
        name = COALESCE(p_name, name),
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
    WHERE id = p_branch_id AND tenant_id = p_tenant_id; -- Security check added
END;
$$;
