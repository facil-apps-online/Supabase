CREATE OR REPLACE FUNCTION public.update_treatment_category_assignments(
    p_tenant_id uuid,
    p_treatment_id uuid,
    p_category_ids uuid[]
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    -- Validate that the treatment belongs to the tenant of the user making the call
    -- The user's tenant is implicitly checked by the RLS policy on the junction table
    IF NOT EXISTS (SELECT 1 FROM public.treatments WHERE id = p_treatment_id AND tenant_id = p_tenant_id) THEN
        RAISE EXCEPTION 'Treatment not found or access denied.';
    END IF;

    -- First, delete existing assignments for the given treatment
    DELETE FROM public.treatment_category_assignments tca
    WHERE tca.treatment_id = p_treatment_id;

    -- Then, insert the new assignments if any are provided
    IF array_length(p_category_ids, 1) > 0 THEN
        INSERT INTO public.treatment_category_assignments (treatment_id, category_id)
        SELECT p_treatment_id, unnest(p_category_ids);
    END IF;
END;
$$;
