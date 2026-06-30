ALTER TABLE public.system_alerts ADD COLUMN platform_id UUID;

-- Populate platform_id based on existing platform names
UPDATE public.system_alerts sa
SET platform_id = p.id
FROM public.platforms p
WHERE sa.platform = p.name;

-- Make platform_id NOT NULL
ALTER TABLE public.system_alerts ALTER COLUMN platform_id SET NOT NULL;

-- Drop the old platform (TEXT) column
ALTER TABLE public.system_alerts DROP COLUMN platform;

-- RLS policies might need to be updated to reflect the change from 'platform' to 'platform_id'.
