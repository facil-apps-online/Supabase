-- First, we need to find the name of the unique constraint on the 'name' column.
-- This is often 'tenants_name_key', but it can vary. We will attempt to drop it with the common name.
-- If this fails, the user will need to provide the correct constraint name.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM information_schema.table_constraints
        WHERE constraint_name = 'tenants_name_key'
        AND table_name = 'tenants'
        AND constraint_type = 'UNIQUE'
    ) THEN
        ALTER TABLE public.tenants DROP CONSTRAINT tenants_name_key;
    END IF;
END $$;

-- Add the slug column, allowing nulls initially to not break existing rows.
ALTER TABLE public.tenants ADD COLUMN slug TEXT;

-- Add a unique constraint for the combination of country_id and slug.
ALTER TABLE public.tenants ADD CONSTRAINT unique_country_slug UNIQUE (country_id, slug);

-- Add a check to ensure the slug is in a valid format (lowercase, no spaces, etc.)
ALTER TABLE public.tenants ADD CONSTRAINT valid_slug_format
CHECK (slug IS NULL OR (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$' AND length(slug) > 2));

COMMENT ON COLUMN public.tenants.slug IS 'The unique slug for the tenant within a country, used for public microsites.';

-- Optional: Backfill existing tenants with a default slug generated from their name
-- This part is commented out as it might require manual intervention to ensure uniqueness.
-- UPDATE public.tenants
-- SET slug = lower(regexp_replace(name, '\s+', '-', 'g'))
-- WHERE slug IS NULL;
-- After backfilling, you might want to alter the column to be NOT NULL:
-- ALTER TABLE public.tenants ALTER COLUMN slug SET NOT NULL;
