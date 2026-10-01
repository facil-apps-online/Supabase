-- Fix update_user_assignments to include platform_id in INSERT
-- The RPC was missing platform_id in the INSERT statement, causing not-null constraint violations

DROP FUNCTION IF EXISTS "public"."update_user_assignments"("p_user_id" "uuid", "p_tenant_id" "uuid", "p_platform_id" "uuid", "p_new_assignments" "jsonb");

CREATE OR REPLACE FUNCTION "public"."update_user_assignments"("p_user_id" "uuid", "p_tenant_id" "uuid", "p_platform_id" "uuid", "p_new_assignments" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    assignment_data jsonb;
BEGIN
    -- Step 1: Delete all existing assignments for this user and tenant.
    DELETE FROM public.user_assignments
    WHERE user_id = p_user_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;

    -- Step 2: Insert all the new assignments from the payload.
    IF jsonb_array_length(p_new_assignments) > 0 THEN
        FOR assignment_data IN SELECT * FROM jsonb_array_elements(p_new_assignments)
        LOOP
            INSERT INTO public.user_assignments (
                user_id, 
                tenant_id, 
                platform_id,
                role_id, 
                branch_id, 
                status,
                base_salary,
                default_product_commission_rate,
                default_service_commission_rate,
                is_schedulable
            )
            VALUES (
                p_user_id,
                p_tenant_id,
                p_platform_id,
                (assignment_data->>'role_id')::uuid,
                CASE
                    WHEN assignment_data->>'branch_id' IS NULL OR assignment_data->>'branch_id' = 'null' THEN NULL
                    ELSE (assignment_data->>'branch_id')::uuid
                END,
                (assignment_data->>'status')::text,
                (assignment_data->>'base_salary')::numeric,
                (assignment_data->>'default_product_commission_rate')::numeric,
                (assignment_data->>'default_service_commission_rate')::numeric,
                COALESCE((assignment_data->>'is_schedulable')::boolean, false)
            );
        END LOOP;
    END IF;
END;
$$;

-- Grant permissions
GRANT ALL ON FUNCTION "public"."update_user_assignments"("p_user_id" "uuid", "p_tenant_id" "uuid", "p_platform_id" "uuid", "p_new_assignments" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."update_user_assignments"("p_user_id" "uuid", "p_tenant_id" "uuid", "p_platform_id" "uuid", "p_new_assignments" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_user_assignments"("p_user_id" "uuid", "p_tenant_id" "uuid", "p_platform_id" "uuid", "p_new_assignments" "jsonb") TO "service_role";