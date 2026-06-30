-- Migration to create the monthly_charges table for storing billing results.
-- Version: 20251104000008

CREATE TABLE public.monthly_charges (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL,
    billing_period_start date NOT NULL,
    billing_period_end date NOT NULL,
    base_plan_charge numeric(10, 2) NOT NULL DEFAULT 0.00,
    total_overage_charge numeric(10, 2) NOT NULL DEFAULT 0.00,
    total_charge numeric(10, 2) NOT NULL DEFAULT 0.00,
    currency_code text NOT NULL,
    currency_symbol text NOT NULL,
    status text NOT NULL DEFAULT 'pending', -- 'pending', 'billed', 'paid', 'failed', 'canceled'
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT monthly_charges_pkey PRIMARY KEY (id),
    CONSTRAINT monthly_charges_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE,
    CONSTRAINT monthly_charges_billing_period_unique UNIQUE (tenant_id, billing_period_start)
);

COMMENT ON TABLE public.monthly_charges IS 'Stores billing cycle results for each tenant, including base plan and overage charges.';

-- Add audit triggers for the new table
create trigger audit_monthly_charges_changes
after INSERT or DELETE or update on monthly_charges for EACH row
execute FUNCTION audit_trigger_function ();

create trigger trigger_monthly_charges_updated_at BEFORE
update on monthly_charges for EACH row
execute FUNCTION update_updated_at_column ();
