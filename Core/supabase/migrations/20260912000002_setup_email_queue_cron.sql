-- Migration: Setup Email Queue Processor Cron Job in Core
-- client_email_queue existe desde el 2026-01-18 (y se usa para password_reset/invitation desde
-- el 2026-09-07), pero nunca se creó un cron ni un webhook que invocara
-- process-client-email-queue — los correos quedaban en PENDING para siempre. Este cron replica
-- el patrón ya usado para WhatsApp (process-whatsapp-queue-job).

-- 1. Create the invocation function (mismo patrón que invoke_core_orphan_cleanup: secretos desde
--    el Vault, nunca hardcodeados en la migración).
CREATE OR REPLACE FUNCTION public.invoke_process_email_queue()
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  project_ref text;
  anon_key text;
  function_url text;
  response json;
BEGIN
  SELECT decrypted_secret INTO project_ref FROM vault.decrypted_secrets WHERE name = 'project_ref';
  SELECT decrypted_secret INTO anon_key FROM vault.decrypted_secrets WHERE name = 'anon_key';

  IF project_ref IS NULL OR anon_key IS NULL THEN
    RAISE EXCEPTION 'project_ref or anon_key not found in vault.decrypted_secrets';
  END IF;

  function_url := 'https://' || project_ref || '.supabase.co/functions/v1/process-client-email-queue';

  SELECT
    net.http_post(
      url := function_url,
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || anon_key
      )
    )
  INTO response;

  RETURN response;
END;
$$;

-- 2. Unschedule if it already exists (idempotente en re-runs).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'process-email-queue-job') THEN
    PERFORM cron.unschedule('process-email-queue-job');
  END IF;
END $$;

-- 3. Schedule the job (every minute, igual que WhatsApp).
SELECT cron.schedule(
  'process-email-queue-job',
  '*/1 * * * *',
  'SELECT public.invoke_process_email_queue();'
);
