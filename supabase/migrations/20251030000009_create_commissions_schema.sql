-- Drop existing tables to ensure a clean slate, handling dependencies.
DROP TABLE IF EXISTS public.payslip_commissions;
DROP TABLE IF EXISTS public.payslips;
DROP TABLE IF EXISTS public.earned_commissions;

-- Recreate the earned_commissions table
create table public.earned_commissions (
  id uuid not null default gen_random_uuid (),
  tenant_id uuid not null,
  branch_id uuid not null,
  user_id uuid not null,
  sale_id uuid not null,
  sales_item_id uuid not null,
  commission_amount numeric(10, 2) not null,
  commission_rate_used numeric(5, 2) not null,
  source_of_rate text not null,
  status text not null default 'earned'::text, -- earned, processing, paid, voided
  void_reason text null, -- Reason for voiding the commission
  created_at timestamp with time zone not null default now(),
  constraint earned_commissions_pkey primary key (id),
  constraint earned_commissions_sale_id_fkey foreign KEY (sale_id) references sales (id) on delete CASCADE,
  constraint earned_commissions_branch_id_fkey foreign KEY (branch_id) references branches (id) on delete CASCADE,
  constraint earned_commissions_tenant_id_fkey foreign KEY (tenant_id) references tenants (id) on delete CASCADE,
  constraint earned_commissions_user_id_fkey foreign KEY (user_id) references auth.users (id) on delete CASCADE,
  constraint earned_commissions_sales_item_id_fkey foreign KEY (sales_item_id) references sales_items (id) on delete CASCADE,
  constraint positive_commission check ((commission_amount >= (0)::numeric))
) TABLESPACE pg_default;

create index IF not exists idx_earned_commissions_user_status on public.earned_commissions using btree (tenant_id, user_id, status) TABLESPACE pg_default;

-- Recreate the payslips table
create table public.payslips (
  id uuid not null default gen_random_uuid (),
  tenant_id uuid not null,
  branch_id uuid not null,
  user_id uuid not null,
  payslip_date date not null default now(),
  total_amount numeric(10, 2) not null,
  status text not null default 'pending_signature'::text, -- pending_signature, paid
  payment_method text null,
  notes text null,
  signature_url text null,
  created_at timestamp with time zone not null default now(),
  constraint payslips_pkey primary key (id),
  constraint payslips_branch_id_fkey foreign key (branch_id) references branches (id) on delete cascade,
  constraint payslips_tenant_id_fkey foreign key (tenant_id) references tenants (id) on delete cascade,
  constraint payslips_user_id_fkey foreign key (user_id) references auth.users (id) on delete cascade
) tablespace pg_default;

-- Recreate the payslip_commissions junction table
create table public.payslip_commissions (
  payslip_id uuid not null,
  commission_id uuid not null,
  constraint payslip_commissions_pkey primary key (payslip_id, commission_id),
  constraint payslip_commissions_payslip_id_fkey foreign key (payslip_id) references payslips (id) on delete cascade,
  constraint payslip_commissions_commission_id_fkey foreign key (commission_id) references earned_commissions (id) on delete cascade
) tablespace pg_default;
