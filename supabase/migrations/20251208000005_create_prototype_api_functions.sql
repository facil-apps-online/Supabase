
-- Migration: Funciones de API para la gestión de Plantillas de Tratamientos/Proyectos
-- Version: 20251208000005

-- Habilitar el manejo de JSONB en PL/pgSQL
-- CREATE EXTENSION IF NOT EXISTS plv8; -- Opcional, si se usa javascript/typescript en funciones
-- NOTA: Usaremos principalmente JSONB y funciones SQL nativas para evitar dependencias complejas.

--------------------------------------------------------------------------------
-- 1. FUNCIÓN PARA CREAR UNA PLANTILLA COMPLETA (con sesiones e ítems)
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION create_treatment_prototype(
  p_tenant_id UUID,
  p_business_id UUID,
  p_name TEXT,
  p_description TEXT,
  p_type TEXT,
  p_sessions JSONB -- Array de sesiones: [{ name, description, session_number, items: [{product_id, service_id, quantity, notes}] }]
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
  -- Crear la plantilla principal
  INSERT INTO treatment_prototypes (tenant_id, business_id, name, description, type)
  VALUES (p_tenant_id, p_business_id, p_name, p_description, p_type)
  RETURNING id INTO v_prototype_id;

  -- Iterar sobre las sesiones del JSON de entrada
  FOR v_session IN SELECT * FROM jsonb_array_elements(p_sessions)
  LOOP
    -- Crear cada sesión
    INSERT INTO prototype_sessions (prototype_id, session_number, name, description)
    VALUES (
      v_prototype_id,
      (v_session->>'session_number')::INT,
      v_session->>'name',
      v_session->>'description'
    )
    RETURNING id INTO v_session_id;

    -- Iterar sobre los ítems de cada sesión
    FOR v_item IN SELECT * FROM jsonb_array_elements(v_session->'items')
    LOOP
      -- Crear cada ítem de la sesión
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

  -- Devolver la plantilla completa recién creada
  SELECT get_treatment_prototype_details(v_prototype_id) INTO v_created_prototype;
  RETURN v_created_prototype;
END;
$$;

COMMENT ON FUNCTION create_treatment_prototype IS 'Crea una plantilla de tratamiento/proyecto completa, incluyendo sus sesiones e ítems, a partir de un objeto JSON.';


--------------------------------------------------------------------------------
-- 2. FUNCIÓN PARA OBTENER LOS DETALLES DE UNA PLANTILLA
--------------------------------------------------------------------------------
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
    'created_at', p.created_at,
    'sessions', (
      SELECT jsonb_agg(
        jsonb_build_object(
          'id', s.id,
          'session_number', s.session_number,
          'name', s.name,
          'description', s.description,
          'items', (
            SELECT jsonb_agg(
              jsonb_build_object(
                'id', i.id,
                'product_id', i.product_id,
                'service_id', i.service_id,
                'quantity', i.quantity,
                'notes', i.notes
                -- Opcional: Incluir nombres de producto/servicio
                -- 'product_name', (SELECT name FROM products WHERE id = i.product_id),
                -- 'service_name', (SELECT name FROM services WHERE id = i.service_id)
              ) ORDER BY i.id
            ) FROM prototype_session_items i WHERE i.session_id = s.id
          )
        ) ORDER BY s.session_number
      ) FROM prototype_sessions s WHERE s.prototype_id = p.id
    )
  )
  FROM treatment_prototypes p
  WHERE p.id = p_prototype_id;
$$;

COMMENT ON FUNCTION get_treatment_prototype_details IS 'Obtiene todos los detalles de una plantilla, anidando sus sesiones e ítems en un solo objeto JSON.';


--------------------------------------------------------------------------------
-- 3. FUNCIÓN PARA LISTAR TODAS LAS PLANTILLAS DE UN NEGOCIO
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION list_treatment_prototypes(p_business_id UUID, p_type TEXT)
RETURNS JSONB
LANGUAGE sql
STABLE
AS $$
  SELECT jsonb_agg(
    jsonb_build_object(
      'id', p.id,
      'name', p.name,
      'description', p.description,
      'type', p.type,
      'session_count', (SELECT COUNT(*) FROM prototype_sessions s WHERE s.prototype_id = p.id)
    ) ORDER BY p.name
  )
  FROM treatment_prototypes p
  WHERE p.business_id = p_business_id AND p.type = p_type;
$$;

COMMENT ON FUNCTION list_treatment_prototypes IS 'Lista todas las plantillas de un negocio para un tipo específico (treatment o project), incluyendo el número de sesiones.';


--------------------------------------------------------------------------------
-- 4. FUNCIÓN PARA ELIMINAR UNA PLANTILLA
-- La eliminación en cascada (ON DELETE CASCADE) en las tablas se encarga de
-- borrar las sesiones y los ítems asociados.
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION delete_treatment_prototype(p_prototype_id UUID, p_tenant_id UUID)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_deleted_id UUID;
BEGIN
  DELETE FROM treatment_prototypes
  WHERE id = p_prototype_id AND tenant_id = p_tenant_id
  RETURNING id INTO v_deleted_id;
  
  RETURN v_deleted_id;
END;
$$;

COMMENT ON FUNCTION delete_treatment_prototype IS 'Elimina una plantilla de tratamiento/proyecto. Requiere el ID de la plantilla y el ID del tenant por seguridad.';


--------------------------------------------------------------------------------
-- 5. FUNCIÓN PARA ACTUALIZAR UNA PLANTILLA COMPLETA
-- Esta función es más compleja. Borra las sesiones/ítems existentes y los
-- vuelve a crear a partir del nuevo JSON. Es un enfoque simple y efectivo.
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION update_treatment_prototype(
  p_prototype_id UUID,
  p_tenant_id UUID,
  p_name TEXT,
  p_description TEXT,
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
  -- Actualizar los datos de la plantilla principal
  UPDATE treatment_prototypes
  SET
    name = p_name,
    description = p_description,
    updated_at = now()
  WHERE id = p_prototype_id AND tenant_id = p_tenant_id;

  -- Borrar las sesiones antiguas (y sus ítems en cascada)
  DELETE FROM prototype_sessions WHERE prototype_id = p_prototype_id;

  -- Volver a crear las sesiones e ítems desde el JSON
  FOR v_session IN SELECT * FROM jsonb_array_elements(p_sessions)
  LOOP
    INSERT INTO prototype_sessions (prototype_id, session_number, name, description)
    VALUES (
      p_prototype_id,
      (v_session->>'session_number')::INT,
      v_session->>'name',
      v_session->>'description'
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

  -- Devolver la plantilla actualizada
  SELECT get_treatment_prototype_details(p_prototype_id) INTO v_updated_prototype;
  RETURN v_updated_prototype;
END;
$$;

COMMENT ON FUNCTION update_treatment_prototype IS 'Actualiza una plantilla completa. Borra las sesiones/ítems anteriores y los recrea a partir del nuevo JSON.';
