-- Cleanup Obsolete WhatsApp Queue Process from Services
-- This process has been centralized in Core

-- 1. Remove the Cron Job
SELECT cron.unschedule('process-whatsapp-queue-job');

-- 2. Drop the obsolete invocation function
DROP FUNCTION IF EXISTS public.invoke_process_whatsapp_queue();
