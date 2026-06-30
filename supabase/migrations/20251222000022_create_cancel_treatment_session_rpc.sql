CREATE OR REPLACE FUNCTION public.cancel_treatment_session(p_session_id uuid, p_tenant_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER AS $$
BEGIN
    UPDATE public.client_treatment_sessions
    SET status = 'Cancelada'
    WHERE 
        id = p_session_id 
        AND tenant_id = p_tenant_id -- Seguridad: asegurar que la sesión pertenece al tenant correcto
        AND status = 'pending'; -- Seguridad: solo cancelar sesiones pendientes
END;
$$;