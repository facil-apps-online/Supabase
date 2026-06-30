DROP FUNCTION IF EXISTS public.reactivate_treatment_session(p_session_id uuid, p_tenant_id uuid);

CREATE OR REPLACE FUNCTION public.reactivate_treatment_session(p_session_id uuid, p_tenant_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER AS $$
BEGIN
    UPDATE public.client_treatment_sessions s
    SET status = 'pending'
    FROM public.client_treatments ct -- JOIN
    WHERE 
        s.id = p_session_id 
        AND s.client_treatment_id = ct.id -- JOIN condition
        AND ct.tenant_id = p_tenant_id   -- Security check on the parent table
        AND s.status = 'Cancelada';
END;
$$;