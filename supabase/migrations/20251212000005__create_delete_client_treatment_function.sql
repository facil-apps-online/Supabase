DROP FUNCTION IF EXISTS public.delete_client_treatment(uuid, uuid);

CREATE OR REPLACE FUNCTION public.delete_client_treatment(
    p_client_treatment_id uuid,
    p_tenant_id uuid
)
RETURNS uuid
LANGUAGE 'plpgsql'
AS $BODY$
DECLARE
    v_session_started_count integer;
    v_deleted_id uuid;
BEGIN
    -- Security check: Ensure the treatment belongs to the correct tenant
    IF NOT EXISTS (
        SELECT 1 FROM public.client_treatments 
        WHERE id = p_client_treatment_id AND tenant_id = p_tenant_id
    ) THEN
        RAISE EXCEPTION 'Treatment not found or permission denied';
    END IF;

    -- Check if any session has a status other than 'pending'
    SELECT count(*)
    INTO v_session_started_count
    FROM public.client_treatment_sessions
    WHERE client_treatment_id = p_client_treatment_id
      AND status <> 'pending';

    IF v_session_started_count > 0 THEN
        RAISE EXCEPTION 'No se puede eliminar un tratamiento que ya ha iniciado.';
    END IF;

    -- If checks pass, delete the treatment. Cascade should handle the rest.
    DELETE FROM public.client_treatments
    WHERE id = p_client_treatment_id
    RETURNING id INTO v_deleted_id;

    RETURN v_deleted_id;
END;
$BODY$;
