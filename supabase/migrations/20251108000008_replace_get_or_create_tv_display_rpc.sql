-- This migration consolidates TV display logic into a single robust function.
-- It drops the old, separate functions and creates a new one that handles all cases.

-- Drop the old functions
DROP FUNCTION IF EXISTS get_tv_display_by_code(TEXT);
DROP FUNCTION IF EXISTS create_unregistered_tv();
DROP FUNCTION IF EXISTS get_or_create_tv_display(TEXT); -- Also drop the intermediate version if it exists

-- Create the new unified function
CREATE OR REPLACE FUNCTION get_or_create_tv_display(p_id UUID DEFAULT NULL, p_registration_code TEXT DEFAULT NULL)
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
  -- Priority 1: Use the provided ID if it exists
  IF p_id IS NOT NULL THEN
    SELECT * INTO tv_record FROM public.tv_displays WHERE public.tv_displays.id = p_id;
    IF FOUND THEN
      RETURN QUERY SELECT tv_record.id, tv_record.branch_id, tv_record.registration_code, tv_record.is_registered, tv_record.registered_at, tv_record.last_heartbeat, tv_record.media_playlist_id, tv_record.tenant_id, tv_record.created_at, tv_record.updated_at;
      RETURN;
    END IF;
    -- If ID is provided but not found, we will fall through to create a new record.
    -- This handles cases where localStorage has a stale ID.
  END IF;

  -- Priority 2: Use the registration code if provided
  IF p_registration_code IS NOT NULL THEN
    SELECT * INTO tv_record FROM public.tv_displays WHERE public.tv_displays.registration_code = p_registration_code;
    IF FOUND THEN
      RETURN QUERY SELECT tv_record.id, tv_record.branch_id, tv_record.registration_code, tv_record.is_registered, tv_record.registered_at, tv_record.last_heartbeat, tv_record.media_playlist_id, tv_record.tenant_id, tv_record.created_at, tv_record.updated_at;
      RETURN;
    END IF;
    -- If code is provided but not found, return nothing. Client should redirect.
    RETURN;
  END IF;

  -- Priority 3: Create a new record if no valid identifier was provided
  LOOP
    generated_code := upper(substr(md5(random()::text), 0, 7));
    IF NOT EXISTS (SELECT 1 FROM public.tv_displays WHERE public.tv_displays.registration_code = generated_code) THEN
      EXIT;
    END IF;
  END LOOP;

  INSERT INTO public.tv_displays (registration_code, is_registered)
  VALUES (generated_code, false)
  RETURNING * INTO tv_record;

  RETURN QUERY SELECT tv_record.id, tv_record.branch_id, tv_record.registration_code, tv_record.is_registered, tv_record.registered_at, tv_record.last_heartbeat, tv_record.media_playlist_id, tv_record.tenant_id, tv_record.created_at, tv_record.updated_at;
END;
$$ LANGUAGE plpgsql VOLATILE SECURITY DEFINER;
