DROP FUNCTION IF EXISTS get_countries_with_timezones();

CREATE OR REPLACE FUNCTION get_countries_with_timezones()
RETURNS TABLE (
  id uuid,
  name text,
  iso_code text,
  is_active boolean,
  default_localization_id uuid,
  default_currency_id uuid,
  timezones text[]
)
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN QUERY
  SELECT
    c.id,
    c.name,
    c.iso_code,
    c.is_active,
    c.default_localization_id,
    c.default_currency_id,
    ARRAY_AGG(tz.name) AS timezones
  FROM
    countries AS c
LEFT JOIN
    country_timezones AS ct ON c.id = ct.country_id
LEFT JOIN
    timezones AS tz ON ct.timezone_id = tz.id
GROUP BY
    c.id, c.name, c.iso_code, c.is_active, c.default_localization_id, c.default_currency_id
ORDER BY
    c.name;
END;
$$;