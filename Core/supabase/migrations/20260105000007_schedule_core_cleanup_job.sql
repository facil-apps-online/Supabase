-- Create a wrapper function to securely call the cleanup Edge Function
create or replace function invoke_core_orphan_cleanup()
returns json
language plpgsql
as $$
declare
  project_ref text;
  anon_key text;
  function_url text;
  response json;
begin
  -- Securely get secrets from the Vault
  select decrypted_secret into project_ref from vault.decrypted_secrets where name = 'project_ref';
  select decrypted_secret into anon_key from vault.decrypted_secrets where name = 'anon_key';

  if project_ref is null or anon_key is null then
    raise exception 'project_ref or anon_key not found in vault.decrypted_secrets';
  end if;

  -- Construct the function URL
  function_url := 'https://' || project_ref || '.supabase.co/functions/v1/core-orphan-cleanup';

  -- Perform the HTTP POST request
  select
      net.http_post(
          url := function_url,
          headers := jsonb_build_object(
              'Content-Type', 'application/json',
              'Authorization', 'Bearer ' || anon_key
          )
      )
  into response;

  return response;
end;
$$;

-- Unschedules the job if it already exists to prevent errors on re-run
DO $$
BEGIN
   IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'core-daily-orphan-cleanup') THEN
      PERFORM cron.unschedule('core-daily-orphan-cleanup');
   END IF;
END
$$;

-- Schedule the new wrapper function to run once daily at 3 AM UTC
SELECT cron.schedule(
  'core-daily-orphan-cleanup',
  '0 3 * * *',
  'SELECT public.invoke_core_orphan_cleanup()'
);