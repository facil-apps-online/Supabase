CREATE OR REPLACE FUNCTION public.reactivate_treatment_session(p_session_id uuid, p_tenant_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER AS $$
BEGIN
    UPDATE public.client_treatment_sessions
    SET status = 'pending'
    WHERE 
        id = p_session_id 
        AND tenant_id = p_tenant_id -- Seguridad: asegurar que la sesión pertenece al tenant correcto
        AND status = 'Cancelada'; -- Seguridad: solo reactivar sesiones canceladas
END;
$$;