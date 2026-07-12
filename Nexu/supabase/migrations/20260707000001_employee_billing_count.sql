-- Create RPC to count active employees for billing purposes
DROP FUNCTION IF EXISTS public.count_active_employees_for_billing(uuid);

CREATE OR REPLACE FUNCTION public.count_active_employees_for_billing(p_tenant_id uuid)
RETURNS integer AS $$
DECLARE
    v_count integer;
BEGIN
    SELECT count(*)::integer
    INTO v_count
    FROM public.employees
    WHERE tenant_id = p_tenant_id
      AND (
          termination_date IS NULL
          OR date_trunc('month', termination_date) = date_trunc('month', current_date)
      );
      
    RETURN v_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
