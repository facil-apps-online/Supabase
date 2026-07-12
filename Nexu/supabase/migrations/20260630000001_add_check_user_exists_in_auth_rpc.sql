DROP FUNCTION IF EXISTS "public"."check_user_exists_in_auth_rpc"("p_email" "text");

CREATE OR REPLACE FUNCTION "public"."check_user_exists_in_auth_rpc"("p_email" "text") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  user_exists boolean;
BEGIN
  SELECT EXISTS (SELECT 1 FROM auth.users WHERE email = p_email) INTO user_exists;
  RETURN user_exists;
END;
$$;

ALTER FUNCTION "public"."check_user_exists_in_auth_rpc"("p_email" "text") OWNER TO "postgres";
GRANT ALL ON FUNCTION "public"."check_user_exists_in_auth_rpc"("p_email" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."check_user_exists_in_auth_rpc"("p_email" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."check_user_exists_in_auth_rpc"("p_email" "text") TO "service_role";
