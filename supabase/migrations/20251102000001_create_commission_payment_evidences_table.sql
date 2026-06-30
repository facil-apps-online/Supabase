create table public.commission_payment_evidences (
  id uuid not null default gen_random_uuid (),
  payslip_id uuid not null,
  google_drive_file_id text not null,
  file_name text not null,
  mime_type text null,
  tenant_id uuid not null,
  branch_id uuid not null,
  user_id uuid null,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),
  file_size bigint null,
  constraint commission_payment_evidences_pkey primary key (id),
  constraint fk_commission_payment_evidences_payslip foreign KEY (payslip_id) references payslips (id) on delete CASCADE,
  constraint fk_commission_payment_evidences_branch foreign KEY (branch_id) references branches (id) on delete CASCADE,
  constraint fk_commission_payment_evidences_tenant foreign KEY (tenant_id) references tenants (id) on delete CASCADE,
  constraint fk_commission_payment_evidences_user foreign KEY (user_id) references auth.users (id) on delete set null
) TABLESPACE pg_default;

create index IF not exists idx_cpe_payslip_id on public.commission_payment_evidences using btree (payslip_id) TABLESPACE pg_default;

create index IF not exists idx_cpe_tenant_id on public.commission_payment_evidences using btree (tenant_id) TABLESPACE pg_default;

create trigger audit_commission_payment_evidences_changes
after INSERT
or DELETE
or
update on commission_payment_evidences for EACH row
execute FUNCTION audit_trigger_function ();

create trigger update_commission_payment_evidences_updated_at BEFORE
update on commission_payment_evidences for EACH row
execute FUNCTION update_updated_at_column ();
