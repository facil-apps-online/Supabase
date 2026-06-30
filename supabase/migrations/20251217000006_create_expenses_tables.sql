-- Creación del tipo ENUM para el estado de los gastos
CREATE TYPE public.expense_status_enum AS ENUM (
    'pending',
    'paid',
    'overdue'
);

-- Definición de la tabla de gastos
CREATE TABLE public.expenses (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL,
    branch_id uuid NOT NULL,
    expense_provider_id uuid NULL,
    amount numeric(10, 2) NOT NULL,
    expense_date date NOT NULL,
    description text NULL,
    status public.expense_status_enum NOT NULL DEFAULT 'pending',
    created_at timestamp with time zone NULL DEFAULT now(),
    updated_at timestamp with time zone NULL DEFAULT now(),
    CONSTRAINT expenses_pkey PRIMARY KEY (id),
    CONSTRAINT fk_expenses_tenant FOREIGN KEY (tenant_id) REFERENCES tenants (id) ON DELETE CASCADE,
    CONSTRAINT fk_expenses_branch FOREIGN KEY (branch_id) REFERENCES branches (id) ON DELETE CASCADE,
    CONSTRAINT fk_expenses_provider FOREIGN KEY (expense_provider_id) REFERENCES expense_providers (id) ON DELETE SET NULL,
    CONSTRAINT expenses_amount_check CHECK (amount > 0)
) TABLESPACE pg_default;

-- Triggers para la tabla de gastos
CREATE TRIGGER audit_changes_on_expenses
AFTER INSERT OR DELETE OR UPDATE ON public.expenses
FOR EACH ROW EXECUTE FUNCTION audit_trigger_function();

CREATE TRIGGER trigger_update_expenses_updated_at
BEFORE UPDATE ON public.expenses
FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();


-- ENUM para el tipo de recurrencia
CREATE TYPE public.recurrence_type_enum AS ENUM (
    'daily',
    'weekly',
    'monthly',
    'yearly'
);

-- Tabla para definir los gastos recurrentes
CREATE TABLE public.recurring_expenses (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL,
    branch_id uuid NOT NULL,
    expense_provider_id uuid NULL,
    amount numeric(10, 2) NOT NULL,
    description text NOT NULL,
    
    -- Columnas para la lógica de recurrencia
    recurrence_type public.recurrence_type_enum NOT NULL,
    recurrence_interval integer NOT NULL DEFAULT 1, -- Ej: si es 'monthly' y el intervalo es 2, será cada 2 meses
    start_date date NOT NULL,
    end_date date NULL, -- Fecha opcional de finalización
    next_generation_date date NOT NULL, -- Fecha en que se debe generar el próximo gasto
    
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamp with time zone NULL DEFAULT now(),
    updated_at timestamp with time zone NULL DEFAULT now(),
    
    CONSTRAINT recurring_expenses_pkey PRIMARY KEY (id),
    CONSTRAINT fk_recurring_expenses_tenant FOREIGN KEY (tenant_id) REFERENCES tenants (id) ON DELETE CASCADE,
    CONSTRAINT fk_recurring_expenses_branch FOREIGN KEY (branch_id) REFERENCES branches (id) ON DELETE CASCADE,
    CONSTRAINT fk_recurring_expenses_provider FOREIGN KEY (expense_provider_id) REFERENCES expense_providers (id) ON DELETE SET NULL,
    CONSTRAINT recurring_expenses_amount_check CHECK (amount > 0),
    CONSTRAINT recurring_expenses_interval_check CHECK (recurrence_interval > 0)
) TABLESPACE pg_default;

-- Triggers para la tabla de gastos recurrentes
CREATE TRIGGER audit_changes_on_recurring_expenses
AFTER INSERT OR DELETE OR UPDATE ON public.recurring_expenses
FOR EACH ROW EXECUTE FUNCTION audit_trigger_function();

CREATE TRIGGER trigger_update_recurring_expenses_updated_at
BEFORE UPDATE ON public.recurring_expenses
FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
