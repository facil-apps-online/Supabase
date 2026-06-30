DROP FUNCTION IF EXISTS public.check_superadmin_exists();

CREATE OR REPLACE FUNCTION public.check_superadmin_exists()
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM auth.users,
         jsonb_array_elements(raw_app_meta_data->'assignments') as assignment
    WHERE assignment->>'role' = 'super_admin'
  );
$$;
