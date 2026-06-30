-- Enum si no existe
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'social_network') THEN
        CREATE TYPE public.social_network AS ENUM ('facebook', 'twitter', 'instagram', 'linkedin', 'youtube', 'tiktok', 'whatsapp', 'website');
    END IF;
END$$;

-- Table: tenant_settings
create table IF NOT EXISTS public.tenant_settings (
  tenant_id uuid not null,
  settings_data jsonb not null default '{}'::jsonb,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),
  platform_id uuid not null,
  constraint tenant_settings_pkey primary key (tenant_id, platform_id),
  constraint tenant_settings_tenant_id_fkey foreign KEY (platform_id, tenant_id) references tenants (platform_id, id) on delete CASCADE
) TABLESPACE pg_default;

create index IF not exists idx_tenant_settings_data on public.tenant_settings using gin (settings_data) TABLESPACE pg_default;

-- Table: tenant_social_networks
create table IF NOT EXISTS public.tenant_social_networks (
  id uuid not null default gen_random_uuid(),
  tenant_id uuid not null,
  network public.social_network not null,
  url text not null,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone null,
  platform_id uuid not null,
  constraint tenant_social_networks_pkey primary key (id, tenant_id, platform_id),
  constraint tenant_social_networks_platform_tenant_network_key unique (platform_id, tenant_id, network),
  constraint tenant_social_networks_tenant_id_fkey foreign KEY (tenant_id, platform_id) references tenants (id, platform_id) on delete CASCADE,
  constraint tenant_social_networks_url_check check ((url ~* '^https?://'::text))
) TABLESPACE pg_default;

-- RLS
ALTER TABLE public.tenant_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tenant_social_networks ENABLE ROW LEVEL SECURITY;
