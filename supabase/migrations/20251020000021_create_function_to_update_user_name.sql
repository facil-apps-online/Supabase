CREATE OR REPLACE FUNCTION public.update_user_name(
  user_id_to_update UUID,
  new_first_name TEXT,
  new_last_name TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE auth.users
  SET
    raw_user_meta_data = raw_user_meta_data || jsonb_build_object(
      'first_name', new_first_name,
      'last_name', new_last_name
    )
  WHERE id = user_id_to_update;
END;
$$;