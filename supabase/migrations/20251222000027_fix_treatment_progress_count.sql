DROP FUNCTION IF EXISTS public.get_client_treatments(p_client_id uuid);

CREATE OR REPLACE FUNCTION public.get_client_treatments(p_client_id uuid)
 RETURNS TABLE(id uuid, name text, status text, start_date date, progress jsonb, has_scheduled_sessions boolean)
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN QUERY
    WITH treatment_progress AS (
        SELECT
            cts.client_treatment_id,
            COUNT(*) AS total,
            -- CORREGIDO: Contar todos los estados que no son 'pending' como "actividad"
            COUNT(*) FILTER (WHERE cts.status IN ('completed', 'Cita Asignada', 'Cancelada')) AS completed,
            BOOL_OR(cts.status = 'Cita Asignada') as has_scheduled_sessions
        FROM
            public.client_treatment_sessions cts
        GROUP BY
            cts.client_treatment_id
    )
    SELECT
        ct.id,
        ct.name,
        ct.status,
        ct.start_date,
        jsonb_build_object(
            'total', COALESCE(tp.total, 0),
            'completed', COALESCE(tp.completed, 0)
        ) AS progress,
        COALESCE(tp.has_scheduled_sessions, false) as has_scheduled_sessions
    FROM
        public.client_treatments ct
    LEFT JOIN
        treatment_progress tp ON ct.id = tp.client_treatment_id
    WHERE
        ct.client_id = p_client_id
    ORDER BY
        ct.created_at DESC;
END;
$function$;