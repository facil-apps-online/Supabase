-- Recreamos la tabla tenants para igualarla a la estructura de Services
DROP TABLE IF EXISTS public.tenants CASCADE;

create table public.tenants (
  id uuid not null default gen_random_uuid (),
  name text not null,
  subscription_status text not null default 'trial'::text,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),
  default_language_code text null,
  default_currency_id uuid null,
  default_timezone text null,
  contact_person text null,
  contact_email text null,
  contact_phone text null,
  country_id uuid null,
  is_active boolean null default true,
  logo_url text null,
  notes text null,
  legal_name text null,
  tax_id text null,
  billing_address text null,
  website text null,
  whatsapp_phone text null,
  einvoicing_email text null,
  physical_address_line1 text null,
  physical_address_line2 text null,
  physical_city text null,
  physical_state text null,
  physical_postal_code text null,
  latitude numeric(10, 7) null,
  longitude numeric(10, 7) null,
  commercial_email text null,
  integrations_mode text not null default 'production'::text,
  is_system_owner boolean not null default false,
  platform_id uuid not null,
  primary_color text null,
  secondary_color text null,
  slug text null,
  description text null,
  constraint tenants_pkey primary key (id, platform_id),
  constraint unique_platform_country_slug unique (platform_id, country_id, slug),
  constraint tenants_subscription_status_check check (
    (
      subscription_status = any (
        array[
          'trial'::text,
          'active'::text,
          'inactive'::text,
          'expired'::text,
          'canceled'::text,
          'grace_period'::text
        ]
      )
    )
  ),
  constraint valid_slug_format check (
    (
      (slug is null)
      or (
        (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'::text)
        and (length(slug) > 2)
      )
    )
  )
) TABLESPACE pg_default;

create index IF not exists idx_tenants_country_id on public.tenants using btree (country_id) TABLESPACE pg_default;

create unique INDEX IF not exists unique_owner_per_platform on public.tenants using btree (platform_id) TABLESPACE pg_default
where
  (is_system_owner = true);

DROP TRIGGER IF EXISTS trigger_tenants_updated_at ON public.tenants;
create trigger trigger_tenants_updated_at BEFORE
update on public.tenants for EACH row
execute FUNCTION update_updated_at_column ();

DROP TRIGGER IF EXISTS update_tenants_updated_at ON public.tenants;
create trigger update_tenants_updated_at BEFORE
update on public.tenants for EACH row
execute FUNCTION update_updated_at_column ();
