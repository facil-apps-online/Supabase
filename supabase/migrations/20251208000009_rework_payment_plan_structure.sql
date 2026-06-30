
-- Migration: [REWORK-CONSOLIDADO] Rediseñar estructura de precios y pagos para mayor flexibilidad
-- Version: 20251208000009

-- 1. Eliminar la columna de plan de pagos por defecto de la tabla de prototipos.
ALTER TABLE treatment_prototypes
DROP COLUMN IF EXISTS default_payment_plan;

-- 2. Añadir columnas a las sesiones del prototipo para definir la cuota
--    por porcentaje o por monto fijo.
ALTER TABLE prototype_sessions
ADD COLUMN IF NOT EXISTS payment_percentage NUMERIC(5, 2) NULL,
ADD COLUMN IF NOT EXISTS fixed_payment_amount NUMERIC(10, 2) NULL;

-- 3. Añadir una restricción para asegurar que solo uno de los dos métodos de pago se use a la vez.
--    Primero, la eliminamos si existe para evitar errores en re-ejecuciones.
ALTER TABLE prototype_sessions
DROP CONSTRAINT IF EXISTS payment_method_check;
ALTER TABLE prototype_sessions
ADD CONSTRAINT payment_method_check 
CHECK (num_nonnulls(payment_percentage, fixed_payment_amount) <= 1);

COMMENT ON COLUMN prototype_sessions.payment_percentage IS 'Cuota de esta sesión como un porcentaje del precio total financiado.';
COMMENT ON COLUMN prototype_sessions.fixed_payment_amount IS 'Cuota de esta sesión como un monto fijo.';

-- 4. Eliminar la tabla separada de pagos de clientes, ya que ahora estará en cada sesión del cliente.
DROP TABLE IF EXISTS client_treatment_payments;

-- 5. Añadir la columna de monto a pagar en las sesiones del cliente.
ALTER TABLE client_treatment_sessions
ADD COLUMN IF NOT EXISTS payment_amount NUMERIC(10, 2) DEFAULT 0.00;

COMMENT ON COLUMN client_treatment_sessions.payment_amount IS 'Monto final a pagar en esta sesión específica del cliente.';

-- 6. Añadir una columna en el tratamiento del cliente para saber qué tipo de precio se eligió.
ALTER TABLE client_treatments
ADD COLUMN IF NOT EXISTS payment_type TEXT;

COMMENT ON COLUMN client_treatments.payment_type IS 'Indica el tipo de precio elegido por el cliente (ej: upfront, financed).';
