CREATE OR REPLACE FUNCTION public.update_branch(
    p_branch_id uuid,
    p_tenant_id uuid,
    p_name text,
    p_address text,
    p_timezone text,
    p_contact_phone text,
    p_whatsapp_phone text,
    p_commercial_email text,
    p_website text,
    p_physical_address_line1 text,
    p_physical_address_line2 text,
    p_physical_city text,
    p_physical_state text,
    p_physical_postal_code text,
    p_latitude numeric,
    p_longitude numeric
)
RETURNS SETOF public.branches AS $$
BEGIN
    RETURN QUERY
    UPDATE public.branches
    SET
        name = COALESCE(p_name, name),
        address = COALESCE(p_address, address),
        timezone = COALESCE(p_timezone, timezone),
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
        updated_at = now()
    WHERE
        id = p_branch_id AND tenant_id = p_tenant_id
    RETURNING *;
END;
$$ LANGUAGE plpgsql;
