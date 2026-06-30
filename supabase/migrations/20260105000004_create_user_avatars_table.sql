create table public.user_avatars (
  id uuid not null default gen_random_uuid(),
  user_id uuid not null, -- Referencia lógica a auth.users(id) en Core
  tenant_id uuid not null,
  platform_id uuid not null, -- Referencia lógica a public.platforms(id) en Core
  google_drive_file_id text not null,
  file_name text null,
  file_size bigint null,
  mime_type text null,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),
  constraint user_avatars_pkey primary key (id),
  constraint fk_user_avatars_tenant foreign KEY (tenant_id) references tenants (id) on delete CASCADE,
  -- Un usuario solo puede tener un avatar por tenant en una plataforma
  constraint user_avatars_user_tenant_platform_key unique (user_id, tenant_id, platform_id)
);

-- Indices y Triggers
create index if not exists idx_user_avatars_user_id on public.user_avatars using btree (user_id);
create index if not exists idx_user_avatars_platform_id on public.user_avatars using btree (platform_id);

create trigger handle_updated_at before
update on public.user_avatars for each row
execute function moddatetime ('updated_at');

create trigger on_avatar_deleted
after delete on public.user_avatars for each row
execute function handle_google_drive_file_delete();
