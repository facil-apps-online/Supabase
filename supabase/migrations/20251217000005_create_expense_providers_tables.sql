-- Definición de la tabla principal para proveedores de gastos
CREATE TABLE public.expense_providers (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    identification_number text NOT NULL,
    name text NOT NULL,
    phone text NULL,
    email text NULL,
    is_active boolean NULL DEFAULT true,
    created_at timestamp with time zone NULL DEFAULT now(),
    updated_at timestamp with time zone NULL DEFAULT now(),
    tenant_id uuid NOT NULL,
    branch_id uuid NULL,
    branch_ids uuid[] NULL,
    document_type_id uuid NULL,
    address_line_1 text NULL,
    address_line_2 text NULL,
    city text NULL,
    state text NULL,
    postal_code text NULL,
    country text NULL,
    latitude numeric NULL,
    longitude numeric NULL,
    CONSTRAINT expense_providers_pkey PRIMARY KEY (id),
    CONSTRAINT expense_providers_identification_number_tenant_id_key UNIQUE (identification_number, tenant_id),
    CONSTRAINT fk_expense_providers_document_type FOREIGN KEY (document_type_id) REFERENCES document_types (id) ON DELETE SET NULL,
    CONSTRAINT fk_expense_providers_tenant FOREIGN KEY (tenant_id) REFERENCES tenants (id) ON DELETE CASCADE
) TABLESPACE pg_default;

-- Triggers para auditoría y actualización de fecha de modificación
CREATE TRIGGER audit_changes_on_expense_providers
AFTER INSERT OR DELETE OR UPDATE ON public.expense_providers
FOR EACH ROW EXECUTE FUNCTION audit_trigger_function();

CREATE TRIGGER trigger_update_expense_providers_updated_at
BEFORE UPDATE ON public.expense_providers
FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Tabla para los contactos de los proveedores de gastos
CREATE TABLE public.expense_provider_contacts (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    expense_provider_id uuid NOT NULL,
    name text NOT NULL,
    email text NULL,
    phone text NULL,
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    tenant_id uuid NOT NULL,
    contact_type_id uuid NOT NULL,
    CONSTRAINT expense_provider_contacts_pkey PRIMARY KEY (id),
    CONSTRAINT fk_expense_provider_contacts_contact_type FOREIGN KEY (contact_type_id) REFERENCES contact_types (id) ON DELETE SET NULL,
    CONSTRAINT fk_expense_provider_contacts_provider FOREIGN KEY (expense_provider_id) REFERENCES expense_providers (id) ON DELETE CASCADE,
    CONSTRAINT fk_expense_provider_contacts_tenant FOREIGN KEY (tenant_id) REFERENCES tenants (id) ON DELETE CASCADE
) TABLESPACE pg_default;

-- Tabla para las direcciones de los proveedores de gastos
CREATE TABLE public.expense_provider_addresses (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    expense_provider_id uuid NOT NULL,
    address_line_1 text NULL,
    address_line_2 text NULL,
    city text NULL,
    state text NULL,
    postal_code text NULL,
    country text NULL,
    latitude float8 NULL,
    longitude float8 NULL,
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    tenant_id uuid NOT NULL,
    name text NULL,
    CONSTRAINT expense_provider_addresses_pkey PRIMARY KEY (id),
    CONSTRAINT fk_expense_provider_addresses_provider FOREIGN KEY (expense_provider_id) REFERENCES expense_providers (id) ON DELETE CASCADE,
    CONSTRAINT fk_expense_provider_addresses_tenant FOREIGN KEY (tenant_id) REFERENCES tenants (id) ON DELETE CASCADE
) TABLESPACE pg_default;
