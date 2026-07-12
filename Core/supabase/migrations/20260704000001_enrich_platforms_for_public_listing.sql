-- Migration: Enrich platforms table and add categories for the public listings portal.
-- Affects: public.platforms, public.platform_categories, public.platform_category_translations

BEGIN;

-- 1. Enrich public.platforms with portal-facing columns.
ALTER TABLE public.platforms
  ADD COLUMN IF NOT EXISTS slug             text,
  ADD COLUMN IF NOT EXISTS status           text NOT NULL DEFAULT 'production',
  ADD COLUMN IF NOT EXISTS logo_url         text,
  ADD COLUMN IF NOT EXISTS description_en   text,
  ADD COLUMN IF NOT EXISTS social_facebook  text,
  ADD COLUMN IF NOT EXISTS social_instagram text,
  ADD COLUMN IF NOT EXISTS display_order    integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS is_public        boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS category_id      uuid,
  ADD COLUMN IF NOT EXISTS updated_at       timestamp with time zone NOT NULL DEFAULT now();

-- Backfill slug for existing rows (deterministic, lowercased, ASCII-safe).
UPDATE public.platforms
SET slug = lower(regexp_replace(name, '[^a-zA-Z0-9]+', '-', 'g'))
WHERE slug IS NULL;

ALTER TABLE public.platforms
  ALTER COLUMN slug SET NOT NULL,
  ADD CONSTRAINT platforms_slug_key UNIQUE (slug);

-- Status domain.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'platforms_status_check'
  ) THEN
    ALTER TABLE public.platforms
      ADD CONSTRAINT platforms_status_check
      CHECK (status IN ('production', 'development', 'planning'));
  END IF;
END$$;

-- 2. Categories table (kept separate to allow growth and reuse).
CREATE TABLE IF NOT EXISTS public.platform_categories (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug        text NOT NULL UNIQUE,
  display_order integer NOT NULL DEFAULT 0,
  created_at  timestamp with time zone NOT NULL DEFAULT now()
);

-- 3. Per-locale category labels.
CREATE TABLE IF NOT EXISTS public.platform_category_translations (
  category_id uuid NOT NULL REFERENCES public.platform_categories(id) ON DELETE CASCADE,
  locale      text NOT NULL,
  name        text NOT NULL,
  PRIMARY KEY (category_id, locale)
);

-- 4. Wire platforms -> category.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'platforms_category_id_fkey'
  ) THEN
    ALTER TABLE public.platforms
      ADD CONSTRAINT platforms_category_id_fkey
      FOREIGN KEY (category_id) REFERENCES public.platform_categories(id) ON DELETE SET NULL;
  END IF;
END$$;

-- 5. Indexes for the portal listing query (is_public, ordered by display_order + name).
CREATE INDEX IF NOT EXISTS idx_platforms_public_listing
  ON public.platforms (is_public, display_order, name)
  WHERE is_public = true;

CREATE INDEX IF NOT EXISTS idx_platforms_category
  ON public.platforms (category_id);

-- 6. Seed categories (4 root buckets). The user will fill in specifics later.
WITH new_cats AS (
  INSERT INTO public.platform_categories (slug, display_order) VALUES
    ('erp',                10),
    ('documentos-y-datos', 20),
    ('recursos-humanos',   30),
    ('comunicaciones',     40)
  ON CONFLICT (slug) DO NOTHING
  RETURNING id, slug
), all_cats AS (
  SELECT id, slug FROM new_cats
  UNION
  SELECT id, slug FROM public.platform_categories
    WHERE slug IN ('erp', 'documentos-y-datos', 'recursos-humanos', 'comunicaciones')
)
INSERT INTO public.platform_category_translations (category_id, locale, name)
SELECT c.id, t.locale, t.name
FROM all_cats c
JOIN (VALUES
  ('erp',                'es', 'ERP'),
  ('erp',                'en', 'ERP'),
  ('documentos-y-datos', 'es', 'Documentos y Datos'),
  ('documentos-y-datos', 'en', 'Documents & Data'),
  ('recursos-humanos',   'es', 'Recursos Humanos'),
  ('recursos-humanos',   'en', 'Human Resources'),
  ('comunicaciones',     'es', 'Comunicaciones'),
  ('comunicaciones',     'en', 'Communications')
) AS t(slug, locale, name) ON c.slug = t.slug
ON CONFLICT (category_id, locale) DO NOTHING;

-- 7. Reasonable display_order for the existing 10 rows (preserve current creation order).
--    User can re-order later via the admin / SQL.
WITH ordered AS (
  SELECT id, row_number() OVER (ORDER BY created_at, name) - 1 AS rn
  FROM public.platforms
)
UPDATE public.platforms p
SET display_order = ordered.rn
FROM ordered
WHERE p.id = ordered.id
  AND p.display_order = 0;

-- 8. Auto-bump updated_at.
CREATE OR REPLACE FUNCTION public.tg_set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_platforms_updated_at ON public.platforms;
CREATE TRIGGER trg_platforms_updated_at
  BEFORE UPDATE ON public.platforms
  FOR EACH ROW
  EXECUTE FUNCTION public.tg_set_updated_at();

COMMIT;
