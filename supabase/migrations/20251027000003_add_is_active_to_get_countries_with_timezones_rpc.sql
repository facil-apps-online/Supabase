DROP FUNCTION IF EXISTS get_countries_with_timezones();

CREATE OR REPLACE FUNCTION get_countries_with_timezones()
RETURNS TABLE (
  id uuid,
  name text,
  iso_code text,
  is_active boolean,
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
    ARRAY_REMOVE(ARRAY_AGG(tz.name), NULL) AS timezones
  FROM
    countries AS c
LEFT JOIN
    country_timezones AS ct ON c.id = ct.country_id
LEFT JOIN
    timezones AS tz ON ct.timezone_id = tz.id
GROUP BY
    c.id, c.name, c.iso_code, c.is_active
ORDER BY
    c.name;
END;
$$;