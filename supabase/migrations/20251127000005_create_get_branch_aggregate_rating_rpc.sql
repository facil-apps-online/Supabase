CREATE OR REPLACE FUNCTION public.get_branch_aggregate_rating(
    p_branch_id uuid,
    p_tenant_id uuid
)
RETURNS TABLE (
    average_rating numeric,
    review_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY
    SELECT
        COALESCE(AVG(ssr.rating), 0)::numeric(3, 2) AS average_rating,
        COUNT(ssr.id)::bigint AS review_count
    FROM
        public.satisfaction_survey_ratings ssr
    WHERE
        ssr.branch_id = p_branch_id
        AND ssr.tenant_id = p_tenant_id;
END;
$$;

COMMENT ON FUNCTION public.get_branch_aggregate_rating(uuid, uuid) IS 'Calculates the aggregate rating (average and count) for a specific branch from satisfaction survey ratings.';
