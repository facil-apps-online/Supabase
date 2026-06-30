CREATE OR REPLACE FUNCTION "public"."get_api_health_stats"()
RETURNS json
LANGUAGE "plpgsql"
AS $$
BEGIN
    -- Clean up old records
    DELETE FROM public.api_request_metrics WHERE created_at < now() - interval '2 months';

    -- Return the statistics
    RETURN (
        WITH metrics_last_hour AS (
            SELECT
                response_time_ms,
                status_code,
                created_at,
                path
            FROM public.api_request_metrics
            WHERE created_at >= now() - interval '60 minutes'
        ),
        metrics_last_month AS (
            SELECT
                response_time_ms,
                path,
                created_at
            FROM public.api_request_metrics
            WHERE created_at >= now() - interval '1 month'
        ),
        rpm_data AS (
            SELECT
                date_trunc('minute', created_at) AS time_bucket,
                count(*) AS request_count
            FROM metrics_last_hour
            GROUP BY time_bucket
            ORDER BY time_bucket
        ),
        high_latency_grouped AS (
            SELECT
                path,
                count(*) as total,
                avg(response_time_ms) as avg_latency,
                max(response_time_ms) as max_latency
            FROM metrics_last_month
            WHERE response_time_ms > 1000
            GROUP BY path
            ORDER BY total DESC
        )
        SELECT json_build_object(
            'avg_latency_ms', (SELECT COALESCE(avg(response_time_ms), 0) FROM metrics_last_hour),
            'error_rate_percentage', (
                SELECT COALESCE(
                    (count(*) FILTER (WHERE status_code >= 500) * 100.0) / NULLIF(count(*), 0),
                    0
                )
                FROM metrics_last_hour
            ),
            'high_latency_requests', (SELECT COALESCE(sum(total), 0) FROM high_latency_grouped),
            'high_latency_list', (SELECT COALESCE(json_agg(high_latency_grouped), '[]'::json) FROM high_latency_grouped),
            'requests_per_minute', (SELECT COALESCE(json_agg(rpm_data), '[]'::json) FROM rpm_data)
        )
    );
END;
$$;