-- This migration cleans up the old, overloaded create_branch functions,
-- leaving only the single comprehensive version created in a previous migration.

DROP FUNCTION IF EXISTS public.create_branch(text, text, text, text, text, text, text, text, text, text, text, numeric, numeric);
DROP FUNCTION IF EXISTS public.create_branch(uuid, text, text);
DROP FUNCTION IF EXISTS public.create_branch(uuid, text, text, text, text, text, text, text, text, text, text, text, numeric, numeric);
-- Note: The most comprehensive overload is intentionally NOT dropped, as it is the one we want to keep.
-- DROP FUNCTION IF EXISTS public.create_branch(uuid, text, text, text, text, text, text, text, text, text, text, text, numeric, numeric, text);
