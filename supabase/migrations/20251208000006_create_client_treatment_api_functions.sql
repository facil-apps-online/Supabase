
-- Migration: Funciones de API para la gestión de Tratamientos de Clientes
-- Version: 20251208000006 (Corregida)

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

COMMENT ON FUNCTION assign_prototype_to_client IS 'Asigna una plantilla a un cliente, creando su tratamiento personalizado con sesiones y plan de pagos.';


--------------------------------------------------------------------------------
-- 2. FUNCIÓN PARA OBTENER LOS DETALLES DE UN TRATAMIENTO DE CLIENTE
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_client_treatment_details(p_client_treatment_id UUID)
RETURNS JSONB
LANGUAGE sql
STABLE
AS $$
  SELECT jsonb_build_object(
    'id', ct.id,
    'client_id', ct.client_id,
    'prototype_id', ct.prototype_id,
    'name', ct.name,
    'final_price', ct.final_price,
    'status', ct.status,
    'start_date', ct.start_date,
    'sessions', (
      SELECT jsonb_agg(
        jsonb_build_object(
          'id', cts.id,
          'session_number', cts.session_number,
          'name', cts.name,
          'description', cts.description,
          'status', cts.status,
          'completed_at', cts.completed_at,
          'attention_id', cts.attention_id,
          'payment_due', (
            SELECT jsonb_build_object(
              'id', ctp.id,
              'amount', ctp.amount,
              'status', ctp.status
            )
            FROM client_treatment_payments ctp
            WHERE ctp.due_session_id = cts.id
          )
        ) ORDER BY cts.session_number
      ) FROM client_treatment_sessions cts WHERE cts.client_treatment_id = ct.id
    )
  )
  FROM client_treatments ct
  WHERE ct.id = p_client_treatment_id;
$$;

COMMENT ON FUNCTION get_client_treatment_details IS 'Obtiene los detalles completos de un tratamiento de un cliente, incluyendo el estado de cada sesión y los pagos asociados.';


--------------------------------------------------------------------------------
-- 3. FUNCIÓN PARA LISTAR LOS TRATAMIENTOS DE UN CLIENTE
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_client_treatments(p_client_id UUID)
RETURNS JSONB
LANGUAGE sql
STABLE
AS $$
  SELECT jsonb_agg(
    jsonb_build_object(
      'id', ct.id,
      'name', ct.name,
      'status', ct.status,
      'start_date', ct.start_date,
      'progress', (
        SELECT jsonb_build_object(
          'completed', COUNT(*) FILTER (WHERE status = 'completed'),
          'total', COUNT(*)
        ) FROM client_treatment_sessions WHERE client_treatment_id = ct.id
      )
    ) ORDER BY ct.start_date DESC
  )
  FROM client_treatments ct
  WHERE ct.client_id = p_client_id;
$$;

COMMENT ON FUNCTION get_client_treatments IS 'Lista todos los tratamientos de un cliente con un resumen de su progreso.';


--------------------------------------------------------------------------------
-- 4. FUNCIÓN PARA MARCAR UNA SESIÓN COMO COMPLETADA
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION complete_client_treatment_session(
  p_session_id UUID,
  p_attention_id UUID,
  p_tenant_id UUID
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_updated_id UUID;
  v_client_treatment_id UUID;
  v_completed_count INT;
  v_total_count INT;
BEGIN
  -- Asegurarse que la sesión pertenezca al tenant por seguridad
  SELECT ct.id INTO v_client_treatment_id
  FROM client_treatment_sessions cts
  JOIN client_treatments ct ON cts.client_treatment_id = ct.id
  WHERE cts.id = p_session_id AND ct.business_id IN (
    SELECT b.id FROM businesses b WHERE b.tenant_id = p_tenant_id
  );

  IF v_client_treatment_id IS NULL THEN
    RAISE EXCEPTION 'Session not found or permission denied';
  END IF;

  -- Actualizar la sesión
  UPDATE client_treatment_sessions
  SET
    status = 'completed',
    completed_at = now(),
    attention_id = p_attention_id
  WHERE id = p_session_id
  RETURNING id INTO v_updated_id;

  -- Verificar si todas las sesiones del tratamiento están completas
  SELECT COUNT(*), COUNT(*) FILTER (WHERE status = 'completed')
  INTO v_total_count, v_completed_count
  FROM client_treatment_sessions
  WHERE client_treatment_id = v_client_treatment_id;

  -- Si todas están completas, actualizar el tratamiento principal
  IF v_total_count > 0 AND v_total_count = v_completed_count THEN
    UPDATE client_treatments
    SET status = 'completed'
    WHERE id = v_client_treatment_id;
  END IF;

  RETURN v_updated_id;
END;
$$;

COMMENT ON FUNCTION complete_client_treatment_session IS 'Marca una sesión como completada y verifica si el tratamiento entero ha finalizado.';
