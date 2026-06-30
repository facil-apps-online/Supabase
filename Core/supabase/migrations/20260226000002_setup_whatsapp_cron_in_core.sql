-- Setup WhatsApp Queue Processor Cron Job in Core
-- This centralizes the WhatsApp sending process

-- 1. Create the invocation function
CREATE OR REPLACE FUNCTION public.invoke_process_whatsapp_queue()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
    PERFORM net.http_post(
        url := 'https://lvdrwumtbhvbtolqgrwi.supabase.co/functions/v1/process-whatsapp-queue',
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imx2ZHJ3dW10Ymh2YnRvbHFncndpIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc2Njg0MjY4NSwiZXhwIjoyMDgyNDE4Njg1fQ.Knh0tXKUT8yd6PmQ4WeJFOXwLwOqREdbsGH4ktgglF0'
        ),
        body := '{}'::jsonb
    );
END;
$function$;

-- 2. Schedule the Cron Job (Every minute)
SELECT cron.schedule(
    'process-whatsapp-queue-job',
    '*/1 * * * *',
    'SELECT public.invoke_process_whatsapp_queue();'
);
