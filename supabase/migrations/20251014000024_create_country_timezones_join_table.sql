-- Create the join table for countries and timezones
CREATE TABLE public.country_timezones (
    country_id UUID NOT NULL,
    timezone_id UUID NOT NULL,
    PRIMARY KEY (country_id, timezone_id),
    FOREIGN KEY (country_id) REFERENCES public.countries(id) ON DELETE CASCADE,
    FOREIGN KEY (timezone_id) REFERENCES public.timezones(id) ON DELETE CASCADE
);

-- Remove the old timezone column from the countries table
-- WARNING: This will delete existing timezone data for countries.
ALTER TABLE public.countries DROP COLUMN IF EXISTS timezone;

-- Add the original_countries column to the timezones table
ALTER TABLE public.timezones ADD COLUMN original_countries text[];

-- Add a comment to the new column
COMMENT ON COLUMN "public"."timezones"."original_countries" IS 'Array of ISO codes of countries where this timezone is originally from.';
