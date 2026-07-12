-- Table to track employee photo uploads for storage space monitoring
-- Each employee can have one active photo; reuploadeletes the old record

create table public.employee_photos (
  id uuid not null default gen_random_uuid(),
  employee_id uuid not null,
  tenant_id uuid not null,
  platform_id uuid not null,
  google_drive_file_id text not null,
  file_name text null,
  file_size bigint null,
  mime_type text null,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),
  constraint employee_photos_pkey primary key (id),
  constraint fk_employee_photos_tenant foreign key (tenant_id) references tenants (id) on delete cascade,
  constraint fk_employee_photos_employee foreign key (employee_id) references employees (id) on delete cascade,
  constraint employee_photos_employee_tenant_platform_key unique (employee_id, tenant_id, platform_id)
);

create index if not exists idx_employee_photos_employee_id on public.employee_photos using btree (employee_id);
create index if not exists idx_employee_photos_tenant_id on public.employee_photos using btree (tenant_id);

alter table public.employee_photos enable row level security;

-- Tenant members can view photos
create policy "Tenant members can view employee photos"
  on public.employee_photos for select
  using (tenant_id = public.get_user_tenant_id(auth.uid()));

-- Portal employees can view their own photo
create policy "Portal employees can view own photo"
  on public.employee_photos for select
  using (employee_id = public.get_current_employee_id());

-- Tenant members can manage employee photos (admin side)
create policy "Tenant members can manage employee photos"
  on public.employee_photos for all
  using (tenant_id = public.get_user_tenant_id(auth.uid()))
  with check (tenant_id = public.get_user_tenant_id(auth.uid()));

-- Portal employees can insert/update their own photo (replaces old via unique constraint)
create policy "Portal employees can manage own photo"
  on public.employee_photos for insert
  with check (employee_id = public.get_current_employee_id());

grant all on public.employee_photos to service_role;
