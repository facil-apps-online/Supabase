-- This migration fixes the security setting for the get_or_create_tv_display function
-- to allow it to bypass RLS policies, which is necessary for it to work correctly.

CREATE OR REPLACE FUNCTION get_or_create_tv_display(p_registration_code TEXT DEFAULT NULL)
RETURNS TABLE (
  id uuid,
  branch_id uuid,
  registration_code text,
  is_registered boolean,
  registered_at timestamp with time zone,
  last_heartbeat timestamp with time zone,
  media_playlist_id uuid,
  tenant_id uuid,
  created_at timestamp with time zone,
  updated_at timestamp with time zone
) AS $$
DECLARE
  tv_record RECORD;
  generated_code TEXT;
BEGIN
  IF p_registration_code IS NOT NULL THEN
    -- Try to find the TV display with the provided code
    SELECT * INTO tv_record FROM public.tv_displays WHERE public.tv_displays.registration_code = p_registration_code;
    
    IF FOUND THEN
      -- Return the found record
      RETURN QUERY SELECT tv_record.id, tv_record.branch_id, tv_record.registration_code, tv_record.is_registered, tv_record.registered_at, tv_record.last_heartbeat, tv_record.media_playlist_id, tv_record.tenant_id, tv_record.created_at, tv_record.updated_at;
      RETURN;
    END IF;
    
    -- If code is provided but not found, return nothing.
    -- The client will see an empty result and should redirect to /tv to get a new code.
    RETURN;
  END IF;

  -- If p_registration_code is NULL, create a new TV display
  LOOP
    generated_code := upper(substr(md5(random()::text), 0, 7));
    IF NOT EXISTS (SELECT 1 FROM public.tv_displays WHERE public.tv_displays.registration_code = generated_code) THEN
      EXIT;
    END IF;
  END LOOP;

  -- Insert the new record and return it
  INSERT INTO public.tv_displays (registration_code, is_registered)
  VALUES (generated_code, false)
  RETURNING * INTO tv_record;

  RETURN QUERY SELECT tv_record.id, tv_record.branch_id, tv_record.registration_code, tv_record.is_registered, tv_record.registered_at, tv_record.last_heartbeat, tv_record.media_playlist_id, tv_record.tenant_id, tv_record.created_at, tv_record.updated_at;
END;
$$ LANGUAGE plpgsql VOLATILE SECURITY DEFINER;
