
-- Migration: Añadir precios y plan de pago por defecto a las plantillas de tratamiento
-- Version: 20251208000008

ALTER TABLE treatment_prototypes
ADD COLUMN upfront_price NUMERIC(10, 2) DEFAULT 0.00,
ADD COLUMN financed_price NUMERIC(10, 2) DEFAULT 0.00,
ADD COLUMN default_payment_plan JSONB;

COMMENT ON COLUMN treatment_prototypes.upfront_price IS 'Precio total del tratamiento si se paga de contado.';
COMMENT ON COLUMN treatment_prototypes.financed_price IS 'Precio total del tratamiento si se paga de forma financiada.';
COMMENT ON COLUMN treatment_prototypes.default_payment_plan IS 'Define el plan de pagos por defecto para la opción financiada. Ej: [{"session_number": 1, "percentage": 50}, {"session_number": 3, "percentage": 50}]';
