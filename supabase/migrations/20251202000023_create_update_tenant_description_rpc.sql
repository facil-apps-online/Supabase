-- Migration to create a dedicated RPC function for updating the tenant description.

CREATE OR REPLACE FUNCTION public.update_tenant_description(
    p_tenant_id uuid,
    p_description text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    UPDATE public.tenants
    SET
        description = p_description,
        updated_at = now()
    WHERE id = p_tenant_id;
END;
$$;
