CREATE OR REPLACE FUNCTION "public"."get_public_phone_prefixes"() RETURNS SETOF "public"."phone_prefixes"
    LANGUAGE "sql" SECURITY DEFINER
    AS $$
  SELECT *
  FROM public.phone_prefixes
  ORDER BY country_name ASC;
$$;

ALTER FUNCTION "public"."get_public_phone_prefixes"() OWNER TO "postgres";
