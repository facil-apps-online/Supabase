-- Migración: Configuración de Reporting por plataforma
-- Proyecto: Core
-- Describe la configuración que Facil Reports necesita para cada plataforma:
--   - API key de reporting (la que la plataforma usa como X-API-Key)
--   - Proyecto Supabase propio de la plataforma (donde vive su edge function google-drive-upload)
--   - Carpeta de Google Drive para plantillas .repx

BEGIN;

-- 1. Tabla: platform_reporting_config
CREATE TABLE IF NOT EXISTS public.platform_reporting_config (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    platform_id uuid NOT NULL,
    reporting_api_key text NOT NULL,
    api_key_prefix text NOT NULL DEFAULT '',
    supabase_url text,
    supabase_service_key text,
    drive_folder_id text,
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    updated_at timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT platform_reporting_config_pkey PRIMARY KEY (id),
    CONSTRAINT platform_reporting_config_platform_id_key UNIQUE (platform_id),
    CONSTRAINT platform_reporting_config_api_key_key UNIQUE (reporting_api_key),
    CONSTRAINT platform_reporting_config_platform_id_fkey
        FOREIGN KEY (platform_id) REFERENCES public.platforms(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_platform_reporting_config_active
    ON public.platform_reporting_config (reporting_api_key)
    WHERE is_active = true;

-- 2. RLS
ALTER TABLE public.platform_reporting_config ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'public' AND tablename = 'platform_reporting_config'
    ) THEN
        CREATE POLICY "Allow ALL for super_admin"
            ON public.platform_reporting_config
            USING (is_super_admin())
            WITH CHECK (is_super_admin());
    END IF;
END$$;

-- 3. Seed con las plataformas actuales del ecosistema
--    (las service keys se llenan desde la consola de cada proyecto Supabase)
INSERT INTO public.platform_reporting_config
    (platform_id, reporting_api_key, api_key_prefix, supabase_url, supabase_service_key, drive_folder_id)
VALUES
    ('ca9090c3-f6a3-46c3-af1d-6362e2942e5f', 'glamtica_live_GENERATE_WITH_OPENSSL', 'glamtica_live_', 'https://vtfsbogpkrcbfuhhoepf.supabase.co', '', ''),
    ('6a6f73c8-2224-4eaf-b40d-da41bd75958a', 'tattoosuite_live_GENERATE_WITH_OPENSSL', 'tattoosuite_live_', 'https://vtfsbogpkrcbfuhhoepf.supabase.co', '', ''),
    ('d9a6ffdc-d1cc-4080-83c7-a9249800a94e', 'nexu_live_GENERATE_WITH_OPENSSL', 'nexu_live_', 'https://znhkucidmjsrzgcuheov.supabase.co', '', ''),
    ('acd97b41-2e4d-4742-9a80-5e6e9acb7958', 'faculfactura_live_GENERATE_WITH_OPENSSL', 'faculfactura_live_', '', '', '')
ON CONFLICT (platform_id) DO NOTHING;

COMMIT;
