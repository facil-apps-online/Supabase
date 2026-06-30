-- Migration to fix the get_user_time_off_history function by correcting the 'approved_by' column type.

-- First, drop the existing function
DROP FUNCTION IF EXISTS public.get_user_time_off_history(uuid, uuid, text, text, date, date, uuid, text);

-- Then, create the function with the corrected return type for approved_by
CREATE OR REPLACE FUNCTION public.get_user_time_off_history(
    p_tenant_id uuid,
    p_user_id uuid,
    p_status_filter text,
    p_type_filter text,
    p_date_range_start date,
    p_date_range_end date,
    p_branch_id uuid,
    p_search_term text
)
RETURNS TABLE(
    id uuid,
    user_id uuid,
    user_name text,
    branch_id uuid,
    branch_name text,
    start_date timestamp with time zone,
    end_date timestamp with time zone,
    absence_type_id uuid,
    absence_type_name text,
    reason text,
    status text,
    approved_by text, -- Corrected type from uuid to text
    created_at timestamp with time zone,
    is_partial_day boolean
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    WITH tenant_users AS (
        SELECT
            gtu.user_id AS tu_user_id,
            gtu.first_name,
            gtu.last_name,
            gtu.email,
            gtu.branch_id AS tu_branch_id,
            gtu.branch_name
        FROM get_tenant_users(p_tenant_id) gtu
    )
    SELECT
        uto.id,
        uto.user_id,
        tu.first_name || ' ' || tu.last_name as user_name,
        uto.branch_id,
        tu.branch_name,
        uto.start_date,
        uto.end_date,
        uto.absence_type_id,
        at.name as absence_type_name,
        uto.reason,
        uto.status,
        uto.approved_by,
        uto.created_at,
        uto.is_partial_day
    FROM
        public.user_time_off uto
    JOIN
        tenant_users tu ON uto.user_id = tu.tu_user_id AND uto.branch_id IS NOT DISTINCT FROM tu.tu_branch_id
    LEFT JOIN
        public.absence_types at ON uto.absence_type_id = at.id
    WHERE
        uto.tenant_id = p_tenant_id
        AND (p_user_id IS NULL OR uto.user_id = p_user_id)
        AND (p_branch_id IS NULL OR uto.branch_id = p_branch_id)
        AND (
            p_status_filter IS NULL OR p_status_filter = 'all' OR
            (CASE
                -- Check if it looks like a JSON array
                WHEN p_status_filter LIKE '[%' AND p_status_filter LIKE '%]' THEN
                    uto.status = ANY(SELECT jsonb_array_elements_text(p_status_filter::jsonb))
                -- Otherwise, treat as a single string
                ELSE
                    uto.status = p_status_filter
            END)
        )
        AND (p_type_filter IS NULL OR p_type_filter = 'all' OR uto.absence_type_id::text = p_type_filter)
        -- Corrected date range filter to check for overlap of the time off period
        AND (p_date_range_start IS NULL OR uto.end_date >= p_date_range_start)
        AND (p_date_range_end IS NULL OR uto.start_date <= p_date_range_end)
        AND (
            p_search_term IS NULL OR p_search_term = '' OR
            (
                -- Search across multiple fields for the full search term
                tu.first_name || ' ' || tu.last_name ILIKE '%' || p_search_term || '%' OR
                tu.email ILIKE '%' || p_search_term || '%' OR
                at.name ILIKE '%' || p_search_term || '%'
            )
        )
    ORDER BY uto.start_date DESC, uto.created_at DESC;
END;
$$;
