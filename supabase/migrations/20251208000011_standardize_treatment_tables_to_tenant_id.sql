-- Migration: Estandarizar a `tenant_id` en las tablas y funciones del módulo de tratamientos.
-- Version: 20251208000011

-- 1. Renombrar la columna `business_id` a `tenant_id` para estandarizar.
ALTER TABLE treatment_prototypes RENAME COLUMN business_id TO tenant_id;
ALTER TABLE client_treatments RENAME COLUMN business_id TO tenant_id;


-- 2. Redefinir la función `create_treatment_prototype` para que use `p_tenant_id` consistentemente.
DROP FUNCTION IF EXISTS create_treatment_prototype(UUID, UUID, TEXT, TEXT, TEXT, NUMERIC, NUMERIC, JSONB);

CREATE OR REPLACE FUNCTION create_treatment_prototype(
  p_tenant_id UUID,
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
  -- Usar `tenant_id` en lugar de `business_id`
  INSERT INTO treatment_prototypes (tenant_id, name, description, type, upfront_price, financed_price)
  VALUES (p_tenant_id, p_name, p_description, p_type, p_upfront_price, p_financed_price)
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
COMMENT ON FUNCTION create_treatment_prototype IS '[FIX] Usa tenant_id en lugar de business_id.';


-- 3. Redefinir la función `update_treatment_prototype` para que use `p_tenant_id`.
DROP FUNCTION IF EXISTS update_treatment_prototype(UUID, UUID, TEXT, TEXT, NUMERIC, NUMERIC, JSONB);

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
  -- Usar `tenant_id` en la cláusula WHERE
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
COMMENT ON FUNCTION update_treatment_prototype IS '[FIX] Usa tenant_id para la autorización en la cláusula WHERE.';


-- 4. Redefinir la función `assign_prototype_to_client` para que use `p_tenant_id`.
DROP FUNCTION IF EXISTS assign_prototype_to_client(UUID, UUID, UUID, UUID, TEXT, DATE, NUMERIC);

CREATE OR REPLACE FUNCTION assign_prototype_to_client(
  p_tenant_id UUID,
  p_client_id UUID,
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

  -- Usar `tenant_id` en la inserción
  INSERT INTO client_treatments (client_id, tenant_id, prototype_id, name, final_price, start_date, payment_type)
  VALUES (p_client_id, p_tenant_id, p_prototype_id, v_prototype.name, v_final_price, p_start_date, p_selected_price_type)
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
COMMENT ON FUNCTION assign_prototype_to_client IS '[FIX] Usa tenant_id y no business_id, acorde al estándar.';
