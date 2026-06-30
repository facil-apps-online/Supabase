-- Add the new timezones column
ALTER TABLE public.countries ADD COLUMN timezones jsonb;

-- Migrate the data from the old timezone column to the new timezones column
UPDATE public.countries SET timezones = jsonb_build_array(timezone) WHERE timezone IS NOT NULL;

-- Remove the old timezone column
ALTER TABLE public.countries DROP COLUMN timezone;

-- Add a comment to the new column
COMMENT ON COLUMN "public"."countries"."timezones" IS 'Lista de zonas horarias para este país (ej. ["America/New_York", "America/Chicago"]).';
