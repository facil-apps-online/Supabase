CREATE OR REPLACE FUNCTION public.update_user_assignments(p_user_id uuid, p_tenant_id uuid, p_new_assignments jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    assignment_data jsonb;
BEGIN
    -- Step 1: Delete all existing assignments for this user and tenant.
    DELETE FROM public.user_assignments
    WHERE user_id = p_user_id AND tenant_id = p_tenant_id;

    -- Step 2: Insert all the new assignments from the payload.
    IF jsonb_array_length(p_new_assignments) > 0 THEN
        FOR assignment_data IN SELECT * FROM jsonb_array_elements(p_new_assignments)
        LOOP
            INSERT INTO public.user_assignments (
                user_id, 
                tenant_id, 
                role_id, 
                branch_id, 
                status,
                base_salary,
                default_product_commission_rate,
                default_service_commission_rate,
                is_schedulable -- The missing field
            )
            VALUES (
                p_user_id,
                p_tenant_id,
                (assignment_data->>'role_id')::uuid,
                CASE
                    WHEN assignment_data->>'branch_id' IS NULL OR assignment_data->>'branch_id' = 'null' THEN NULL
                    ELSE (assignment_data->>'branch_id')::uuid
                END,
                (assignment_data->>'status')::text,
                (assignment_data->>'base_salary')::numeric,
                (assignment_data->>'default_product_commission_rate')::numeric,
                (assignment_data->>'default_service_commission_rate')::numeric,
                COALESCE((assignment_data->>'is_schedulable')::boolean, false) -- The missing value, defaulting to false
            );
        END LOOP;
    END IF;
END;
$$;