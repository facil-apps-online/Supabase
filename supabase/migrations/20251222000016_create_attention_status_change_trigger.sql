-- 1. Crear la función del Trigger
CREATE OR REPLACE FUNCTION public.handle_attention_status_change()
RETURNS TRIGGER AS $$
DECLARE
  v_session_ids_to_update uuid[];
BEGIN
  -- Solo ejecutar si el estado realmente cambió
  IF NEW.status = OLD.status THEN
    RETURN NEW;
  END IF;

  -- Encontrar todas las session_ids únicas asociadas a esta atención
  -- Usamos una subconsulta con UNION para recolectar IDs de todas las tablas relevantes
  SELECT array_agg(DISTINCT session_id)
  INTO v_session_ids_to_update
  FROM (
    SELECT client_treatment_session_id as session_id FROM public.attention_services WHERE attention_id = NEW.id AND client_treatment_session_id IS NOT NULL
    UNION
    SELECT client_treatment_session_id as session_id FROM public.attention_products WHERE attention_id = NEW.id AND client_treatment_session_id IS NOT NULL
    -- Descomentar si la tabla de pagos también tiene la referencia
    -- UNION
    -- SELECT client_treatment_session_id as session_id FROM public.attention_payments WHERE attention_id = NEW.id AND client_treatment_session_id IS NOT NULL
  ) AS all_session_items;
  
  -- Si no hay sesiones asociadas, no hacer nada
  IF v_session_ids_to_update IS NULL OR array_length(v_session_ids_to_update, 1) = 0 THEN
    RETURN NEW;
  END IF;

  -- Caso 1: La atención se cancela
  IF NEW.status = 'Cancelada' THEN
    UPDATE public.client_treatment_sessions
    SET 
      status = 'Pendiente',
      attention_id = NULL
    WHERE id = ANY(v_session_ids_to_update);
  
  -- Caso 2: La atención se marca como pagada
  ELSIF NEW.status = 'Pagada' THEN
    UPDATE public.client_treatment_sessions
    SET 
      status = 'completed' -- Se usa 'completed' que ya existe en la tabla
    WHERE id = ANY(v_session_ids_to_update);
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 2. Crear el Trigger en la tabla 'attentions'
DROP TRIGGER IF EXISTS attentions_status_change_trigger ON public.attentions; -- Para idempotencia

CREATE TRIGGER attentions_status_change_trigger
AFTER UPDATE ON public.attentions
FOR EACH ROW
EXECUTE FUNCTION public.handle_attention_status_change();
