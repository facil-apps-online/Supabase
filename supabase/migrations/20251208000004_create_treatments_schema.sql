
-- Esquema de Base de Datos: Módulo de Tratamientos/Proyectos
-- Version: 20251208000004

-- Tabla: treatment_prototypes
-- Almacena las plantillas maestras para tratamientos o proyectos.
CREATE TABLE treatment_prototypes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL, -- REFERENCES businesses(id) assumed
    name TEXT NOT NULL,
    description TEXT,
    -- 'treatment' para Glamtica, 'project' para Tattoo Suite
    type TEXT NOT NULL CHECK (type IN ('treatment', 'project')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE treatment_prototypes IS 'Plantillas maestras para tratamientos (Glamatica) o proyectos (Tattoo Suite).';

-- Tabla: prototype_sessions
-- Define las diferentes sesiones o etapas que componen una plantilla de tratamiento/proyecto.
CREATE TABLE prototype_sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    prototype_id UUID NOT NULL REFERENCES treatment_prototypes(id) ON DELETE CASCADE,
    session_number INT NOT NULL,
    name TEXT NOT NULL,
    description TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(prototype_id, session_number)
);
COMMENT ON TABLE prototype_sessions IS 'Define las sesiones o etapas de una plantilla de tratamiento/proyecto.';

-- Tabla: prototype_session_items
-- Especifica los productos o servicios que se deben utilizar en cada sesión de una plantilla.
CREATE TABLE prototype_session_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id UUID NOT NULL REFERENCES prototype_sessions(id) ON DELETE CASCADE,
    product_id UUID, -- REFERENCES products(id) assumed
    service_id UUID, -- REFERENCES services(id) assumed
    quantity INT NOT NULL DEFAULT 1,
    notes TEXT,
    CHECK (product_id IS NOT NULL OR service_id IS NOT NULL)
);
COMMENT ON TABLE prototype_session_items IS 'Productos y servicios a utilizar en cada sesión de una plantilla.';

-- Tabla: client_treatments
-- Registra una instancia de un tratamiento/proyecto asignado a un cliente específico.
CREATE TABLE client_treatments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id UUID NOT NULL, -- REFERENCES clients(id) assumed
    business_id UUID NOT NULL, -- REFERENCES businesses(id) assumed
    prototype_id UUID REFERENCES treatment_prototypes(id),
    name TEXT NOT NULL,
    final_price NUMERIC(10, 2) NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('active', 'completed', 'cancelled')) DEFAULT 'active',
    start_date DATE NOT NULL DEFAULT CURRENT_DATE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE client_treatments IS 'Instancia de un tratamiento/proyecto asignado a un cliente.';

-- Tabla: client_treatment_sessions
-- Almacena las sesiones específicas para el tratamiento de un cliente.
CREATE TABLE client_treatment_sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_treatment_id UUID NOT NULL REFERENCES client_treatments(id) ON DELETE CASCADE,
    prototype_session_id UUID REFERENCES prototype_sessions(id),
    session_number INT NOT NULL,
    name TEXT NOT NULL,
    description TEXT,
    status TEXT NOT NULL CHECK (status IN ('pending', 'completed')) DEFAULT 'pending',
    completed_at TIMESTAMPTZ,
    attention_id UUID, -- REFERENCES attentions(id) assumed
    UNIQUE(client_treatment_id, session_number)
);
COMMENT ON TABLE client_treatment_sessions IS 'Sesiones de un tratamiento específico de un cliente, con su propio estado.';

-- Tabla: client_treatment_payments
-- Gestiona las cuotas de pago asociadas a un tratamiento de un cliente.
CREATE TABLE client_treatment_payments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_treatment_id UUID NOT NULL REFERENCES client_treatments(id) ON DELETE CASCADE,
    due_session_id UUID NOT NULL REFERENCES client_treatment_sessions(id),
    amount NUMERIC(10, 2) NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('pending', 'paid')) DEFAULT 'pending',
    paid_at TIMESTAMPTZ,
    payment_id UUID -- REFERENCES payments(id) assumed
);
COMMENT ON TABLE client_treatment_payments IS 'Cuotas de pago para el tratamiento de un cliente.';
