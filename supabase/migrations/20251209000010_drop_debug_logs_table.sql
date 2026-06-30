-- Clean up migration to drop the temporary debug table.

BEGIN;

DROP TABLE IF EXISTS public.debug_logs;

COMMIT;
