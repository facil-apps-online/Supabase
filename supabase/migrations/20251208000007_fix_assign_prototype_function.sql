-- Migration: Corregir la firma y seguridad de la función assign_prototype_to_client
-- Version: 20251208000007

-- Primero, eliminamos la función antigua con la firma incorrecta para evitar la sobrecarga ambigua.
DROP FUNCTION IF EXISTS assign_prototype_to_client(UUID, UUID, UUID, NUMERIC, DATE, JSONB);

--------------------------------------------------------------------------------
-- 1. FUNCIÓN PARA ASIGNAR Y PERSONALIZAR UN TRATAMIENTO A UN CLIENTE (VERSIÓN CORREGIDA)
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION assign_prototype_to_client(
  p_tenant_id UUID, -- Añadido por seguridad
  p_client_id UUID,
  p_business_id UUID,
  p_prototype_id UUID,
  p_final_price NUMERIC,
  p_start_date DATE,
  p_payments JSONB -- Array de pagos: [{ due_session_number, amount }]
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER -- Añadido por seguridad
AS $$
DECLARE
  v_client_treatment_id UUID;
  v_prototype_name TEXT;
  v_session RECORD;
  v_client_session_id UUID;
  v_payment JSONB;
  v_due_session_id UUID;
  v_created_client_treatment JSONB;
  v_is_allowed BOOLEAN;
BEGIN
  -- Verificación de Seguridad: Asegurar que el negocio pertenece al tenant.
  SELECT EXISTS (
    SELECT 1 FROM businesses WHERE id = p_business_id AND tenant_id = p_tenant_id
  ) INTO v_is_allowed;

  IF NOT v_is_allowed THEN
    RAISE EXCEPTION 'Permiso denegado: El negocio no pertenece al tenant actual.';
  END IF;

  -- Obtener nombre del prototipo
  SELECT name INTO v_prototype_name FROM treatment_prototypes WHERE id = p_prototype_id;

  -- 1. Crear el registro principal del tratamiento del cliente
  INSERT INTO client_treatments (client_id, business_id, prototype_id, name, final_price, start_date)
  VALUES (p_client_id, p_business_id, p_prototype_id, v_prototype_name, p_final_price, p_start_date)
  RETURNING id INTO v_client_treatment_id;

  -- 2. Copiar las sesiones de la plantilla a las sesiones del cliente
  FOR v_session IN
    SELECT id, session_number, name, description FROM prototype_sessions WHERE prototype_id = p_prototype_id ORDER BY session_number
  LOOP
    INSERT INTO client_treatment_sessions (client_treatment_id, prototype_session_id, session_number, name, description)
    VALUES (v_client_treatment_id, v_session.id, v_session.session_number, v_session.name, v_session.description);
  END LOOP;

  -- 3. Crear los registros de pago (cuotas)
  FOR v_payment IN SELECT * FROM jsonb_array_elements(p_payments)
  LOOP
    -- Encontrar el ID de la sesión del cliente que corresponde al número de sesión de la cuota
    SELECT id INTO v_due_session_id
    FROM client_treatment_sessions
    WHERE client_treatment_id = v_client_treatment_id
      AND session_number = (v_payment->>'due_session_number')::INT;

    IF v_due_session_id IS NOT NULL THEN
      INSERT INTO client_treatment_payments (client_treatment_id, due_session_id, amount)
      VALUES (v_client_treatment_id, v_due_session_id, (v_payment->>'amount')::NUMERIC);
    END IF;
  END LOOP;

  -- Devolver el tratamiento del cliente recién creado y detallado
  SELECT get_client_treatment_details(v_client_treatment_id) INTO v_created_client_treatment;
  RETURN v_created_client_treatment;
END;
$$;

COMMENT ON FUNCTION assign_prototype_to_client IS 'Asigna una plantilla a un cliente, creando su tratamiento personalizado con sesiones y plan de pagos. Versión corregida con SECURITY DEFINER.';