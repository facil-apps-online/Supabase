-- This migration drops a remaining duplicate signature for the update_branch function.

DROP FUNCTION IF EXISTS public.update_branch(uuid, uuid, text, text, text, text, text, text, text, text, text, text, text, numeric, numeric, text, text);
