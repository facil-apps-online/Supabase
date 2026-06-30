
-- Migration: [REWORK-CONSOLIDADO] Actualizar funciones API para el nuevo modelo de precios y corregir bugs
-- Version: 20251208000010

-- ============================================================================
-- 1. list_treatment_prototypes (CORREGIDA)
--    - Se añade COALESCE para devolver [] en lugar de NULL si no hay resultados.
-- ============================================================================
CREATE OR REPLACE FUNCTION list_treatment_prototypes(p_business_id UUID, p_type TEXT)
RETURNS JSONB
LANGUAGE sql
STABLE
AS $$
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id', p.id,
      'name', p.name,
      'description', p.description,
      'type', p.type,
      'upfront_price', p.upfront_price,
      'financed_price', p.financed_price,
      'session_count', (SELECT COUNT(*) FROM prototype_sessions s WHERE s.prototype_id = p.id)
    ) ORDER BY p.name
  ), '[]'::jsonb)
  FROM treatment_prototypes p
  WHERE p.business_id = p_business_id AND p.type = p_type;
$$;

COMMENT ON FUNCTION list_treatment_prototypes IS '[REWORK] Lista todas las plantillas, devolviendo [] si está vacío.';

-- ============================================================================
-- 2. get_client_treatments (CORREGIDA)
--    - Se añade COALESCE para devolver [] en lugar de NULL si no hay resultados.
-- ============================================================================
CREATE OR REPLACE FUNCTION get_client_treatments(p_client_id UUID)
RETURNS JSONB
LANGUAGE sql
STABLE
AS $$
  SELECT COALESCE(jsonb_agg(
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
  ), '[]'::jsonb)
  FROM client_treatments ct
  WHERE ct.client_id = p_client_id;
$$;

COMMENT ON FUNCTION get_client_treatments IS '[REWORK] Lista todos los tratamientos de un cliente, devolviendo [] si está vacío.';

-- ============================================================================
-- 3. create_treatment_prototype (REWORK)
--    - Acepta cuotas de pago (porcentaje o fijo) a nivel de sesión.
-- ============================================================================
DROP FUNCTION IF EXISTS create_treatment_prototype(UUID, UUID, TEXT, TEXT, TEXT, JSONB);
DROP FUNCTION IF EXISTS create_treatment_prototype(UUID, UUID, TEXT, TEXT, TEXT, NUMERIC, NUMERIC, JSONB, JSONB);

CREATE OR REPLACE FUNCTION create_treatment_prototype(
  p_tenant_id UUID,
  p_business_id UUID,
  p_name TEXT,
  p_description TEXT,
  p_type TEXT,
  p_upfront_price NUMERIC,
  p_financed_price NUMERIC,
  p_sessions JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_prototype_id UUID;
  v_session_id UUID;
  v_session JSONB;
  v_item JSONB;
  v_created_prototype JSONB;
BEGIN
  INSERT INTO treatment_prototypes (tenant_id, business_id, name, description, type, upfront_price, financed_price)
  VALUES (p_tenant_id, p_business_id, p_name, p_description, p_type, p_upfront_price, p_financed_price)
  RETURNING id INTO v_prototype_id;

  FOR v_session IN SELECT * FROM jsonb_array_elements(p_sessions)
  LOOP
    INSERT INTO prototype_sessions (prototype_id, session_number, name, description, payment_percentage, fixed_payment_amount)
    VALUES (
      v_prototype_id,
      (v_session->>'session_number')::INT,
      v_session->>'name',
      v_session->>'description',
      (v_session->>'payment_percentage')::NUMERIC,
      (v_session->>'fixed_payment_amount')::NUMERIC
    )
    RETURNING id INTO v_session_id;

    FOR v_item IN SELECT * FROM jsonb_array_elements(v_session->'items')
    LOOP
      INSERT INTO prototype_session_items (session_id, product_id, service_id, quantity, notes)
      VALUES (
        v_session_id,
        (v_item->>'product_id')::UUID,
        (v_item->>'service_id')::UUID,
        (v_item->>'quantity')::INT,
        v_item->>'notes'
      );
    END LOOP;
  END LOOP;

  SELECT get_treatment_prototype_details(v_prototype_id) INTO v_created_prototype;
  RETURN v_created_prototype;
END;
$$;

COMMENT ON FUNCTION create_treatment_prototype IS '[REWORK] Crea una plantilla con cuotas de pago (porcentaje/fijo) a nivel de sesión.';

-- ============================================================================
-- 4. get_treatment_prototype_details (REWORK)
--    - Devuelve los nuevos campos de pago a nivel de sesión.
-- ============================================================================
CREATE OR REPLACE FUNCTION get_treatment_prototype_details(p_prototype_id UUID)
RETURNS JSONB
LANGUAGE sql
STABLE
AS $$
  SELECT jsonb_build_object(
    'id', p.id,
    'name', p.name,
    'description', p.description,
    'type', p.type,
    'upfront_price', p.upfront_price,
    'financed_price', p.financed_price,
    'created_at', p.created_at,
    'sessions', (
      SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
          'id', s.id,
          'session_number', s.session_number,
          'name', s.name,
          'description', s.description,
          'payment_percentage', s.payment_percentage,
          'fixed_payment_amount', s.fixed_payment_amount,
          'items', (
            SELECT COALESCE(jsonb_agg(
              jsonb_build_object(
                'id', i.id,
                'product_id', i.product_id,
                'service_id', i.service_id,
                'quantity', i.quantity,
                'notes', i.notes
              ) ORDER BY i.id
            ), '[]'::jsonb) FROM prototype_session_items i WHERE i.session_id = s.id
          )
        ) ORDER BY s.session_number
      ), '[]'::jsonb) FROM prototype_sessions s WHERE s.prototype_id = p.id
    )
  )
  FROM treatment_prototypes p
  WHERE p.id = p_prototype_id;
$$;

COMMENT ON FUNCTION get_treatment_prototype_details IS '[REWORK] Obtiene detalles de plantilla, incluyendo cuotas por sesión.';

-- ============================================================================
-- 5. update_treatment_prototype (REWORK)
--    - Actualiza una plantilla con cuotas de pago a nivel de sesión.
-- ============================================================================
DROP FUNCTION IF EXISTS update_treatment_prototype(UUID, UUID, TEXT, TEXT, JSONB);
DROP FUNCTION IF EXISTS update_treatment_prototype(UUID, UUID, TEXT, TEXT, NUMERIC, NUMERIC, JSONB, JSONB);

CREATE OR REPLACE FUNCTION update_treatment_prototype(
  p_prototype_id UUID,
  p_tenant_id UUID,
  p_name TEXT,
  p_description TEXT,
  p_upfront_price NUMERIC,
  p_financed_price NUMERIC,
  p_sessions JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_session_id UUID;
  v_session JSONB;
  v_item JSONB;
  v_updated_prototype JSONB;
BEGIN
  UPDATE treatment_prototypes
  SET
    name = p_name,
    description = p_description,
    upfront_price = p_upfront_price,
    financed_price = p_financed_price,
    updated_at = now()
  WHERE id = p_prototype_id AND tenant_id = p_tenant_id;

  DELETE FROM prototype_sessions WHERE prototype_id = p_prototype_id;

  FOR v_session IN SELECT * FROM jsonb_array_elements(p_sessions)
  LOOP
    INSERT INTO prototype_sessions (prototype_id, session_number, name, description, payment_percentage, fixed_payment_amount)
    VALUES (
      p_prototype_id,
      (v_session->>'session_number')::INT,
      v_session->>'name',
      v_session->>'description',
      (v_session->>'payment_percentage')::NUMERIC,
      (v_session->>'fixed_payment_amount')::NUMERIC
    )
    RETURNING id INTO v_session_id;

    FOR v_item IN SELECT * FROM jsonb_array_elements(v_session->'items')
    LOOP
      INSERT INTO prototype_session_items (session_id, product_id, service_id, quantity, notes)
      VALUES (
        v_session_id,
        (v_item->>'product_id')::UUID,
        (v_item->>'service_id')::UUID,
        (v_item->>'quantity')::INT,
        v_item->>'notes'
      );
    END LOOP;
  END LOOP;

  SELECT get_treatment_prototype_details(p_prototype_id) INTO v_updated_prototype;
  RETURN v_updated_prototype;
END;
$$;

COMMENT ON FUNCTION update_treatment_prototype IS '[REWORK] Actualiza una plantilla con cuotas a nivel de sesión.';

-- ============================================================================
-- 6. assign_prototype_to_client (REWORK)
--    - Calcula el monto a pagar en cada sesión del cliente.
-- ============================================================================
DROP FUNCTION IF EXISTS assign_prototype_to_client(UUID, UUID, UUID, UUID, NUMERIC, DATE, JSONB);
DROP FUNCTION IF EXISTS assign_prototype_to_client(UUID, UUID, UUID, UUID, TEXT, NUMERIC, DATE);

CREATE OR REPLACE FUNCTION assign_prototype_to_client(
  p_tenant_id UUID,
  p_client_id UUID,
  p_business_id UUID,
  p_prototype_id UUID,
  p_selected_price_type TEXT,
  p_start_date DATE,
  p_custom_final_price NUMERIC DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_client_treatment_id UUID;
  v_prototype RECORD;
  v_final_price NUMERIC;
  v_session RECORD;
  v_calculated_payment_amount NUMERIC;
  v_created_client_treatment JSONB;
BEGIN
  SELECT * INTO v_prototype FROM treatment_prototypes WHERE id = p_prototype_id;

  IF p_custom_final_price IS NOT NULL THEN
    v_final_price = p_custom_final_price;
  ELSIF p_selected_price_type = 'upfront' THEN
    v_final_price = v_prototype.upfront_price;
  ELSIF p_selected_price_type = 'financed' THEN
    v_final_price = v_prototype.financed_price;
  ELSE
    RAISE EXCEPTION 'Tipo de precio seleccionado no válido: %', p_selected_price_type;
  END IF;

  INSERT INTO client_treatments (client_id, business_id, prototype_id, name, final_price, start_date, payment_type)
  VALUES (p_client_id, p_business_id, p_prototype_id, v_prototype.name, v_final_price, p_start_date, p_selected_price_type)
  RETURNING id INTO v_client_treatment_id;

  FOR v_session IN
    SELECT * FROM prototype_sessions WHERE prototype_id = p_prototype_id ORDER BY session_number
  LOOP
    v_calculated_payment_amount := 0;
    IF p_selected_price_type = 'upfront' AND v_session.session_number = 1 THEN
      v_calculated_payment_amount := v_final_price;
    ELSIF p_selected_price_type = 'financed' THEN
      IF v_session.fixed_payment_amount IS NOT NULL AND v_session.fixed_payment_amount > 0 THEN
        v_calculated_payment_amount := v_session.fixed_payment_amount;
      ELSIF v_session.payment_percentage IS NOT NULL AND v_session.payment_percentage > 0 THEN
        v_calculated_payment_amount := v_final_price * (v_session.payment_percentage / 100.0);
      END IF;
    END IF;

    INSERT INTO client_treatment_sessions (client_treatment_id, prototype_session_id, session_number, name, description, payment_amount)
    VALUES (v_client_treatment_id, v_session.id, v_session.session_number, v_session.name, v_session.description, v_calculated_payment_amount);
  END LOOP;

  SELECT get_client_treatment_details(v_client_treatment_id) INTO v_created_client_treatment;
  RETURN v_created_client_treatment;
END;
$$;

COMMENT ON FUNCTION assign_prototype_to_client IS '[REWORK] Asigna una plantilla y calcula el monto a pagar en cada sesión.';
