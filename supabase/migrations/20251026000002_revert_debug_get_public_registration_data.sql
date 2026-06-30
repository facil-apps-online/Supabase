CREATE OR REPLACE FUNCTION "public"."get_public_registration_data"() RETURNS json
    LANGUAGE "sql" SECURITY DEFINER
    AS $$
  SELECT json_build_object(
    'countries', (
      SELECT json_agg(
        json_build_object(
          'id', c.id,
          'name', c.name,
          'iso_code', c.iso_code,
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
$$;