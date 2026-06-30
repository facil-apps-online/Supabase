-- Create a wrapper function to securely call the cleanup Edge Function
create or replace function invoke_services_orphan_cleanup()
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
  function_url := 'https://' || project_ref || '.supabase.co/functions/v1/services-orphan-cleanup';

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
-- The DO block handles the case where the job does not exist yet
DO $$
BEGIN
   IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'services-daily-orphan-cleanup') THEN
      PERFORM cron.unschedule('services-daily-orphan-cleanup');
   END IF;
END
$$;

-- Schedule the new wrapper function to run once daily at 2 AM UTC
SELECT cron.schedule(
  'services-daily-orphan-cleanup',
  '0 2 * * *',
  'SELECT public.invoke_services_orphan_cleanup()'
);
