-- 1. Re-Create the Trigger Function with the correct status case
CREATE OR REPLACE FUNCTION public.handle_attention_status_change()
RETURNS TRIGGER AS $$
DECLARE
  v_session_ids_to_update uuid[];
BEGIN
  -- Only execute if the status actually changed
  IF NEW.status = OLD.status THEN
    RETURN NEW;
  END IF;

  -- Find all unique session_ids associated with this attention
  SELECT array_agg(DISTINCT session_id)
  INTO v_session_ids_to_update
  FROM (
    SELECT client_treatment_session_id as session_id FROM public.attention_services WHERE attention_id = NEW.id AND client_treatment_session_id IS NOT NULL
    UNION
    SELECT client_treatment_session_id as session_id FROM public.attention_products WHERE attention_id = NEW.id AND client_treatment_session_id IS NOT NULL
    -- Uncomment if the payments table also has the reference
    -- UNION
    -- SELECT client_treatment_session_id as session_id FROM public.attention_payments WHERE attention_id = NEW.id AND client_treatment_session_id IS NOT NULL
  ) AS all_session_items;
  
  -- If no associated sessions, do nothing
  IF v_session_ids_to_update IS NULL OR array_length(v_session_ids_to_update, 1) = 0 THEN
    RETURN NEW;
  END IF;

  -- Case 1: The attention is cancelled
  IF NEW.status = 'Cancelada' THEN
    UPDATE public.client_treatment_sessions
    SET 
      status = 'pending', -- CORRECTED to lowercase
      attention_id = NULL
    WHERE id = ANY(v_session_ids_to_update);
  
  -- Case 2: The attention is marked as paid
  ELSIF NEW.status = 'Pagada' THEN
    UPDATE public.client_treatment_sessions
    SET 
      status = 'completed' -- This was already correct (lowercase)
    WHERE id = ANY(v_session_ids_to_update);
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 2. The Trigger definition itself does not need to change, 
--    but we execute it again to ensure it's linked to the latest function version.
DROP TRIGGER IF EXISTS attentions_status_change_trigger ON public.attentions;

CREATE TRIGGER attentions_status_change_trigger
AFTER UPDATE ON public.attentions
FOR EACH ROW
EXECUTE FUNCTION public.handle_attention_status_change();
