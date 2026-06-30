-- Migration to add the description field to the get_tenant_settings_data RPC function.

CREATE OR REPLACE FUNCTION "public"."get_tenant_settings_data"(tenant_id_param uuid) RETURNS json
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  RETURN json_build_object(
    'tenant', (
      SELECT json_build_object(
        'id', t.id,
        'name', t.name,
        'logo_url', t.logo_url,
        'slug', t.slug,
        'description', t.description, -- Added
        'country_id', t.country_id,
        'default_language_code', t.default_language_code,
        'default_currency_id', t.default_currency_id,
        'default_timezone', t.default_timezone,
        'contact_phone', t.contact_phone,
        'whatsapp_phone', t.whatsapp_phone,
        'commercial_email', t.commercial_email,
        'legal_name', t.legal_name,
        'tax_id', t.tax_id,
        'billing_address', t.billing_address,
        'einvoicing_email', t.einvoicing_email,
        'physical_address_line1', t.physical_address_line1,
        'physical_address_line2', t.physical_address_line2,
        'physical_city', t.physical_city,
        'physical_state', t.physical_state,
        'physical_postal_code', t.physical_postal_code,
        'website', t.website,
        'latitude', t.latitude,
        'longitude', t.longitude
      )
      FROM tenants t
      WHERE t.id = tenant_id_param
    ),
    'countries', (
      SELECT json_agg(
        json_build_object(
          'id', c.id,
          'name', c.name,
          'iso_code', c.iso_code,
          'is_active', c.is_active,
          'default_localization_id', c.default_localization_id,
          'default_currency_id', c.default_currency_id,
          'timezones', (
            SELECT json_agg(tz.name)
            FROM public.country_timezones ct
            JOIN public.timezones tz ON ct.timezone_id = tz.id
            WHERE ct.country_id = c.id
          )
        )
      )
      FROM countries c
      WHERE c.is_active = true
    ),
    'languages', (
      SELECT json_agg(
        json_build_object(
          'id', l.id,
          'name', l.name,
          'iso_code', l.iso_code
        )
      )
      FROM languages l
      WHERE l.is_active = true
    ),
    'currencies', (
      SELECT json_agg(
        json_build_object(
          'id', curr.id,
          'name', curr.name,
          'symbol', curr.symbol,
          'code', curr.code,
          'decimal_places', curr.decimal_places,
          'symbol_position', curr.symbol_position,
          'decimal_separator', curr.decimal_separator,
          'thousands_separator', curr.thousands_separator
        )
      )
      FROM currencies curr
      WHERE curr.is_active = true
    )
  );
END;
$$;
