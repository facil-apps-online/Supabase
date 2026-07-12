-- Add file_size to signatures for storage tracking
ALTER TABLE public.signatures ADD COLUMN file_size integer;

-- Add logo_file_size to tenants for tracking company logo storage
ALTER TABLE public.tenants ADD COLUMN logo_file_size bigint default 0;

-- RPC to calculate total storage usage per tenant across all Google Drive file types
CREATE OR REPLACE FUNCTION public.get_nexuhr_storage_usage(p_tenant_id UUID)
RETURNS TABLE(category TEXT, size BIGINT)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
    RETURN QUERY
        SELECT 'Fotos de empleados'::TEXT, coalesce(sum(file_size), 0)::BIGINT
        FROM public.employee_photos
        WHERE tenant_id = p_tenant_id

        UNION ALL

        SELECT 'Evidencias'::TEXT, coalesce(sum(file_size), 0)::BIGINT
        FROM public.evidences
        WHERE tenant_id = p_tenant_id

        UNION ALL

        SELECT 'Firmas'::TEXT, coalesce(sum(file_size), 0)::BIGINT
        FROM public.signatures
        WHERE tenant_id = p_tenant_id AND file_size IS NOT NULL

        UNION ALL

        SELECT 'Logo empresa'::TEXT, coalesce(logo_file_size, 0)::BIGINT
        FROM public.tenants
        WHERE id = p_tenant_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_nexuhr_storage_usage(UUID) TO anon, authenticated;

-- Also grant select on employee_photos to authenticated users for the RPC
GRANT ALL ON public.employee_photos TO authenticated;
