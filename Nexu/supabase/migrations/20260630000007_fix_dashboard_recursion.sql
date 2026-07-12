-- =============================================
-- Fix recursion: SECURITY DEFINER + subquery for event_participants
-- =============================================
-- The previous migration used SECURITY INVOKER which caused
-- "infinite recursion detected in policy for relation event_participants"
-- because the RLS policy on event_participants references events,
-- and our alert query JOINed both tables.
--
-- Fix: change to SECURITY DEFINER (existing codebase pattern) and
-- use EXISTS subquery instead of JOIN for event_participants.

DROP FUNCTION IF EXISTS public.get_dashboard_stats(uuid, date, text);

CREATE OR REPLACE FUNCTION public.get_dashboard_stats(
    p_tenant_id      uuid    DEFAULT NULL,
    p_reference_date date    DEFAULT NULL,
    p_timezone       text    DEFAULT 'America/Bogota'
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_caller_tenant_id  uuid;
    v_effective_tenant   uuid;
    v_is_super_admin    boolean;
    v_reference_date     date;
    v_period_start       timestamptz;
    v_period_end         timestamptz;
    v_prev_period_start  timestamptz;

    v_employees          jsonb;
    v_exams              jsonb;
    v_courses            jsonb;
    v_vigilancias        jsonb;
    v_evaluations        jsonb;
    v_communications     jsonb;
    v_notifications      jsonb;

    v_alerts             jsonb;
    v_deadlines          jsonb;
    v_compliance         jsonb;
    v_modules_agg        jsonb;

    v_alert_exams_expired           int;
    v_alert_courses_expiring_30d    int;
    v_alert_evaluations_overdue     int;
    v_alert_event_signatures        int;
    v_alert_copasst_expiring_15d    int;
    v_alert_dotacion_next_7d        int;
    v_alert_incapacidades_review    int;
    v_alerts_total_count            int;
BEGIN
    -- 1. Resolve caller context
    v_caller_tenant_id := public.get_user_tenant_id(auth.uid());
    v_is_super_admin   := public.is_super_admin(auth.uid());

    IF v_caller_tenant_id IS NULL AND NOT v_is_super_admin THEN
        RAISE EXCEPTION 'No tenant associated with the current user'
            USING ERRCODE = '42501';
    END IF;

    -- 2. Effective tenant: explicit param wins only for super admins
    IF p_tenant_id IS NOT NULL THEN
        IF v_is_super_admin OR p_tenant_id = v_caller_tenant_id THEN
            v_effective_tenant := p_tenant_id;
        ELSE
            RAISE EXCEPTION 'Caller is not allowed to query the requested tenant'
                USING ERRCODE = '42501';
        END IF;
    ELSE
        v_effective_tenant := v_caller_tenant_id;
    END IF;

    -- 3. Reference period (current month in the given timezone)
    v_reference_date    := COALESCE(p_reference_date, (now() AT TIME ZONE p_timezone)::date);
    v_period_start      := date_trunc('month', v_reference_date::timestamp AT TIME ZONE p_timezone) AT TIME ZONE p_timezone;
    v_period_end        := (date_trunc('month', v_reference_date::timestamp AT TIME ZONE p_timezone) + interval '1 month') AT TIME ZONE p_timezone;
    v_prev_period_start := v_period_start - interval '1 month';

    -- 4. Employees
    SELECT jsonb_build_object(
        'total_active',     COUNT(*) FILTER (WHERE active = true),
        'total_inactive',   COUNT(*) FILTER (WHERE active = false),
        'new_this_month',   COUNT(*) FILTER (WHERE active = true
                                              AND COALESCE(hire_date::timestamptz, created_at) >= v_period_start
                                              AND COALESCE(hire_date::timestamptz, created_at) <  v_period_end),
        'new_last_month',   COUNT(*) FILTER (WHERE active = true
                                              AND COALESCE(hire_date::timestamptz, created_at) >= v_prev_period_start
                                              AND COALESCE(hire_date::timestamptz, created_at) <  v_period_start),
        'terminated_this_month', COUNT(*) FILTER (WHERE active = false
                                              AND updated_at >= v_period_start
                                              AND updated_at <  v_period_end)
    )
    INTO v_employees
    FROM public.employees
    WHERE tenant_id = v_effective_tenant;

    v_employees := v_employees || jsonb_build_object(
        'trend_pct',
        CASE
            WHEN (v_employees ->> 'new_last_month')::int > 0
                THEN ROUND(
                    (((v_employees ->> 'new_this_month')::int - (v_employees ->> 'new_last_month')::int)::numeric
                     / (v_employees ->> 'new_last_month')::int) * 100
                )::int
            WHEN (v_employees ->> 'new_this_month')::int > 0 THEN 100
            ELSE 0
        END
    );

    -- 5. Exams
    SELECT jsonb_build_object(
        'total',          COUNT(*),
        'vigente',        COUNT(*) FILTER (WHERE status = 'vigente'),
        'vencido',        COUNT(*) FILTER (WHERE status = 'vencido'),
        'proximo_vencer', COUNT(*) FILTER (WHERE status = 'proximo_vencer'),
        'pendiente',      COUNT(*) FILTER (WHERE status = 'pendiente'),
        'pct_vigente',
            CASE WHEN COUNT(*) > 0
                 THEN ROUND((COUNT(*) FILTER (WHERE status = 'vigente'))::numeric / COUNT(*) * 100)::int
                 ELSE 0
            END
    )
    INTO v_exams
    FROM public.exams
    WHERE tenant_id = v_effective_tenant;

    -- 6. Courses
    SELECT jsonb_build_object(
        'total',         COUNT(*),
        'completado',    COUNT(*) FILTER (WHERE status = 'completado'),
        'vencido',       COUNT(*) FILTER (WHERE status = 'vencido'),
        'en_progreso',   COUNT(*) FILTER (WHERE status = 'en_progreso'),
        'pendiente',     COUNT(*) FILTER (WHERE status = 'pendiente'),
        'pct_completado',
            CASE WHEN COUNT(*) > 0
                 THEN ROUND((COUNT(*) FILTER (WHERE status = 'completado'))::numeric / COUNT(*) * 100)::int
                 ELSE 0
            END,
        'expiring_next_30_days',
            COUNT(*) FILTER (WHERE expiry_date IS NOT NULL
                             AND expiry_date >= v_reference_date
                             AND expiry_date <  v_reference_date + interval '30 days')
    )
    INTO v_courses
    FROM public.courses
    WHERE tenant_id = v_effective_tenant;

    -- 7. Vigilancias
    SELECT jsonb_build_object(
        'total',   COUNT(*),
        'activa',  COUNT(*) FILTER (WHERE status = 'activa'),
        'vencida', COUNT(*) FILTER (WHERE status = 'vencida'),
        'inactiva',COUNT(*) FILTER (WHERE status = 'inactiva')
    )
    INTO v_vigilancias
    FROM public.vigilancias
    WHERE tenant_id = v_effective_tenant;

    -- 8. Evaluations
    SELECT jsonb_build_object(
        'total',        COUNT(*),
        'pendiente',    COUNT(*) FILTER (WHERE status = 'pendiente'),
        'en_proceso',   COUNT(*) FILTER (WHERE status = 'en_proceso'),
        'completada',   COUNT(*) FILTER (WHERE status = 'completada'),
        'cancelada',    COUNT(*) FILTER (WHERE status = 'cancelada'),
        'pending',      COUNT(*) FILTER (WHERE status IN ('pendiente', 'en_proceso')),
        'this_month',   COUNT(*) FILTER (WHERE evaluation_date >= v_period_start
                                         AND evaluation_date <  v_period_end)
    )
    INTO v_evaluations
    FROM public.evaluations
    WHERE tenant_id = v_effective_tenant;

    -- 9. Communications
    SELECT jsonb_build_object(
        'total',            COUNT(*),
        'borrador',         COUNT(*) FILTER (WHERE status = 'borrador'),
        'enviado',          COUNT(*) FILTER (WHERE status = 'enviado'),
        'leido',            COUNT(*) FILTER (WHERE status = 'leido'),
        'sent_this_month',  COUNT(*) FILTER (WHERE status = 'enviado'
                                             AND sent_at IS NOT NULL
                                             AND sent_at >= v_period_start
                                             AND sent_at <  v_period_end),
        'created_this_month', COUNT(*) FILTER (WHERE created_at >= v_period_start
                                               AND created_at <  v_period_end)
    )
    INTO v_communications
    FROM public.communications
    WHERE tenant_id = v_effective_tenant;

    -- 10. Notifications
    SELECT jsonb_build_object(
        'total',         COUNT(*),
        'unread',        COUNT(*) FILTER (WHERE read = false),
        'urgent',        COUNT(*) FILTER (WHERE read = false AND type = 'warning'),
        'info',          COUNT(*) FILTER (WHERE read = false AND type = 'info')
    )
    INTO v_notifications
    FROM public.notifications
    WHERE tenant_id = v_effective_tenant
      AND (
          v_is_super_admin
          OR user_id = auth.uid()
          OR employee_id = public.get_current_employee_id()
      );

    -- =========================================================
    -- 11. Alerts (counts only, derived from existing tables)
    -- =========================================================
    SELECT COUNT(*) INTO v_alert_exams_expired
    FROM public.exams
    WHERE tenant_id = v_effective_tenant
      AND (status = 'vencido'
           OR (expiry_date IS NOT NULL AND expiry_date < v_reference_date));

    SELECT COUNT(*) INTO v_alert_courses_expiring_30d
    FROM public.courses
    WHERE tenant_id = v_effective_tenant
      AND expiry_date IS NOT NULL
      AND expiry_date >= v_reference_date
      AND expiry_date <  v_reference_date + interval '30 days';

    SELECT COUNT(*) INTO v_alert_evaluations_overdue
    FROM public.evaluations
    WHERE tenant_id = v_effective_tenant
      AND status IN ('pendiente', 'en_proceso')
      AND evaluation_date < v_reference_date;

    SELECT COUNT(*) INTO v_alert_event_signatures
    FROM public.event_participants ep
    WHERE EXISTS (
        SELECT 1 FROM public.events e
        WHERE e.id = ep.event_id
          AND e.tenant_id = v_effective_tenant
    )
      AND ep.signed = false;

    SELECT COUNT(*) INTO v_alert_copasst_expiring_15d
    FROM public.committees
    WHERE tenant_id = v_effective_tenant
      AND active = true
      AND end_date IS NOT NULL
      AND end_date >= v_reference_date
      AND end_date <  v_reference_date + interval '15 days';

    SELECT COUNT(*) INTO v_alert_dotacion_next_7d
    FROM public.dotacion
    WHERE tenant_id = v_effective_tenant
      AND delivery_date >= v_reference_date
      AND delivery_date <  v_reference_date + interval '7 days';

    SELECT COUNT(*) INTO v_alert_incapacidades_review
    FROM public.incapacidades
    WHERE tenant_id = v_effective_tenant
      AND estado = 'en_revision';

    v_alerts_total_count := v_alert_exams_expired
                           + v_alert_courses_expiring_30d
                           + v_alert_evaluations_overdue
                           + v_alert_event_signatures
                           + v_alert_copasst_expiring_15d
                           + v_alert_dotacion_next_7d
                           + v_alert_incapacidades_review;

    v_alerts := COALESCE(
        (
            SELECT jsonb_agg(alert_obj)
            FROM (
                SELECT jsonb_build_object(
                    'id',          'alert-' || sort_order,
                    'type',        alert_type,
                    'title',       alert_title,
                    'description', alert_description,
                    'count',       alert_count,
                    'sort_order',  sort_order
                ) AS alert_obj
                FROM (
                    VALUES
                    (1,  'urgent',  'Examenes vencidos',
                            CASE WHEN v_alert_exams_expired = 1
                                 THEN '1 examen con fecha vencida'
                                 ELSE v_alert_exams_expired || ' examenes con fecha vencida'
                            END,
                            v_alert_exams_expired),
                    (2,  'urgent',  'Cursos por renovar',
                            CASE WHEN v_alert_courses_expiring_30d = 1
                                 THEN '1 certificacion proxima a vencer en 30 dias'
                                 ELSE v_alert_courses_expiring_30d || ' certificaciones proximas a vencer en 30 dias'
                            END,
                            v_alert_courses_expiring_30d),
                    (3,  'warning', 'Evaluaciones vencidas',
                            CASE WHEN v_alert_evaluations_overdue = 1
                                 THEN '1 evaluacion sin completar despues de su fecha'
                                 ELSE v_alert_evaluations_overdue || ' evaluaciones sin completar despues de su fecha'
                            END,
                            v_alert_evaluations_overdue),
                    (4,  'warning', 'Firmas pendientes',
                            CASE WHEN v_alert_event_signatures = 1
                                 THEN '1 empleado sin firmar en eventos recientes'
                                 ELSE v_alert_event_signatures || ' empleados sin firmar en eventos recientes'
                            END,
                            v_alert_event_signatures),
                    (5,  'warning', 'COPASST proximo a vencer',
                            CASE WHEN v_alert_copasst_expiring_15d = 1
                                 THEN 'La vigencia del comite termina en menos de 15 dias'
                                 ELSE v_alert_copasst_expiring_15d || ' comites terminan su vigencia en menos de 15 dias'
                            END,
                            v_alert_copasst_expiring_15d),
                    (6,  'info',    'Dotacion programada',
                            CASE WHEN v_alert_dotacion_next_7d = 1
                                 THEN '1 entrega de dotacion en los proximos 7 dias'
                                 ELSE v_alert_dotacion_next_7d || ' entregas de dotacion en los proximos 7 dias'
                            END,
                            v_alert_dotacion_next_7d),
                    (7,  'info',    'Incapacidades en revision',
                            CASE WHEN v_alert_incapacidades_review = 1
                                 THEN '1 incapacidad pendiente por revisar'
                                 ELSE v_alert_incapacidades_review || ' incapacidades pendientes por revisar'
                            END,
                            v_alert_incapacidades_review)
                ) AS a(sort_order, alert_type, alert_title, alert_description, alert_count)
                WHERE alert_count > 0
                ORDER BY sort_order
            ) AS ordered_alerts
        ),
        '[]'::jsonb
    );

    -- =========================================================
    -- 12. Upcoming deadlines (top 10 across modules)
    -- =========================================================
    v_deadlines := COALESCE(
        (
            SELECT jsonb_agg(item)
            FROM (
                SELECT item
                FROM (
                    SELECT jsonb_build_object(
                        'id',       'exam-' || e.id,
                        'title',    'Examen ' || COALESCE(e.exam_type, 'medico') || ' - ' ||
                                    COALESCE(emp.first_name || ' ' || emp.last_name, 'Empleado'),
                        'type',     'exam',
                        'date',     to_char(e.scheduled_date, 'DD Mon YYYY'),
                        'days_left',(e.scheduled_date - v_reference_date)
                    ) AS item,
                    (e.scheduled_date - v_reference_date) AS days_left
                    FROM public.exams e
                    LEFT JOIN public.employees emp ON emp.id = e.employee_id
                    WHERE e.tenant_id = v_effective_tenant
                      AND e.scheduled_date IS NOT NULL
                      AND e.scheduled_date >= v_reference_date
                      AND e.scheduled_date <  v_reference_date + interval '60 days'

                    UNION ALL

                    SELECT jsonb_build_object(
                        'id',       'course-' || c.id,
                        'title',    'Curso ' || c.course_name || ' - ' ||
                                    COALESCE(emp.first_name || ' ' || emp.last_name, 'Empleado'),
                        'type',     'training',
                        'date',     to_char(c.expiry_date, 'DD Mon YYYY'),
                        'days_left',(c.expiry_date - v_reference_date)
                    ),
                    (c.expiry_date - v_reference_date)
                    FROM public.courses c
                    LEFT JOIN public.employees emp ON emp.id = c.employee_id
                    WHERE c.tenant_id = v_effective_tenant
                      AND c.expiry_date IS NOT NULL
                      AND c.expiry_date >= v_reference_date
                      AND c.expiry_date <  v_reference_date + interval '60 days'

                    UNION ALL

                    SELECT jsonb_build_object(
                        'id',       'committee-' || c.id,
                        'title',    'Renovacion ' || c.name,
                        'type',     'committee',
                        'date',     to_char(c.end_date, 'DD Mon YYYY'),
                        'days_left',(c.end_date - v_reference_date)
                    ),
                    (c.end_date - v_reference_date)
                    FROM public.committees c
                    WHERE c.tenant_id = v_effective_tenant
                      AND c.active = true
                      AND c.end_date IS NOT NULL
                      AND c.end_date >= v_reference_date
                      AND c.end_date <  v_reference_date + interval '60 days'

                    UNION ALL

                    SELECT jsonb_build_object(
                        'id',       'dotacion-' || d.id,
                        'title',    'Entrega ' || d.item_name || ' - ' ||
                                    COALESCE(emp.first_name || ' ' || emp.last_name, 'Empleado'),
                        'type',     'signature',
                        'date',     to_char(d.delivery_date, 'DD Mon YYYY'),
                        'days_left',(d.delivery_date - v_reference_date)
                    ),
                    (d.delivery_date - v_reference_date)
                    FROM public.dotacion d
                    LEFT JOIN public.employees emp ON emp.id = d.employee_id
                    WHERE d.tenant_id = v_effective_tenant
                      AND d.delivery_date >= v_reference_date
                      AND d.delivery_date <  v_reference_date + interval '60 days'
                ) AS all_items
                ORDER BY days_left ASC
                LIMIT 10
            ) AS top_items
        ),
        '[]'::jsonb
    );

    -- =========================================================
    -- 13. Compliance: scheduled vs completed per module
    -- =========================================================
    v_modules_agg := COALESCE(
        (
            WITH exam_stats AS (
                SELECT
                    COUNT(*) FILTER (WHERE scheduled_date >= v_period_start
                                     AND scheduled_date <  v_period_end) AS scheduled,
                    COUNT(*) FILTER (WHERE scheduled_date >= v_period_start
                                     AND scheduled_date <  v_period_end
                                     AND (status = 'vigente' OR (exam_date IS NOT NULL AND exam_date <= scheduled_date))) AS completed
                FROM public.exams
                WHERE tenant_id = v_effective_tenant
            ),
            course_stats AS (
                SELECT
                    COUNT(*) FILTER (WHERE start_date >= v_period_start
                                     AND start_date <  v_period_end) AS scheduled,
                    COUNT(*) FILTER (WHERE start_date >= v_period_start
                                     AND start_date <  v_period_end
                                     AND status = 'completado') AS completed
                FROM public.courses
                WHERE tenant_id = v_effective_tenant
            ),
            evaluation_stats AS (
                SELECT
                    COUNT(*) FILTER (WHERE evaluation_date >= v_period_start
                                     AND evaluation_date <  v_period_end) AS scheduled,
                    COUNT(*) FILTER (WHERE evaluation_date >= v_period_start
                                     AND evaluation_date <  v_period_end
                                     AND status = 'completada') AS completed
                FROM public.evaluations
                WHERE tenant_id = v_effective_tenant
            ),
            dotacion_stats AS (
                SELECT
                    COUNT(*) FILTER (WHERE delivery_date >= v_period_start
                                     AND delivery_date <  v_period_end) AS scheduled,
                    COUNT(*) FILTER (WHERE delivery_date >= v_period_start
                                     AND delivery_date <  v_period_end
                                     AND delivery_date <= v_reference_date) AS completed
                FROM public.dotacion
                WHERE tenant_id = v_effective_tenant
            )
            SELECT jsonb_agg(row ORDER BY module_key)
            FROM (
                SELECT jsonb_build_object(
                    'module',     'examenes',
                    'scheduled',  exam_stats.scheduled,
                    'completed',  exam_stats.completed,
                    'percentage', CASE WHEN exam_stats.scheduled > 0
                                       THEN ROUND((exam_stats.completed::numeric / exam_stats.scheduled) * 100)::int
                                       ELSE NULL END
                ) AS row,
                'examenes'::text AS module_key
                FROM exam_stats
                UNION ALL
                SELECT jsonb_build_object(
                    'module',     'cursos',
                    'scheduled',  course_stats.scheduled,
                    'completed',  course_stats.completed,
                    'percentage', CASE WHEN course_stats.scheduled > 0
                                       THEN ROUND((course_stats.completed::numeric / course_stats.scheduled) * 100)::int
                                       ELSE NULL END
                ),
                'cursos'::text
                FROM course_stats
                UNION ALL
                SELECT jsonb_build_object(
                    'module',     'evaluaciones',
                    'scheduled',  evaluation_stats.scheduled,
                    'completed',  evaluation_stats.completed,
                    'percentage', CASE WHEN evaluation_stats.scheduled > 0
                                       THEN ROUND((evaluation_stats.completed::numeric / evaluation_stats.scheduled) * 100)::int
                                       ELSE NULL END
                ),
                'evaluaciones'::text
                FROM evaluation_stats
                UNION ALL
                SELECT jsonb_build_object(
                    'module',     'dotacion',
                    'scheduled',  dotacion_stats.scheduled,
                    'completed',  dotacion_stats.completed,
                    'percentage', CASE WHEN dotacion_stats.scheduled > 0
                                       THEN ROUND((dotacion_stats.completed::numeric / dotacion_stats.scheduled) * 100)::int
                                       ELSE NULL END
                ),
                'dotacion'::text
                FROM dotacion_stats
            ) AS all_rows
        ),
        '[]'::jsonb
    );

    v_compliance := jsonb_build_object(
        'modules', v_modules_agg,
        'overall', jsonb_build_object(
            'scheduled',  (SELECT COALESCE(SUM((m ->> 'scheduled')::int), 0) FROM jsonb_array_elements(v_modules_agg) m),
            'completed',  (SELECT COALESCE(SUM((m ->> 'completed')::int), 0) FROM jsonb_array_elements(v_modules_agg) m),
            'percentage', (
                SELECT ROUND(AVG((m ->> 'percentage')::int))::int
                FROM jsonb_array_elements(v_modules_agg) m
                WHERE (m ->> 'percentage') IS NOT NULL
            )
        )
    );

    RETURN jsonb_build_object(
        'tenant_id',      v_effective_tenant,
        'reference_date', v_reference_date,
        'timezone',       p_timezone,
        'period_start',   v_period_start,
        'period_end',     v_period_end,
        'is_super_admin', v_is_super_admin,
        'employees',      COALESCE(v_employees,      '{}'::jsonb),
        'exams',          COALESCE(v_exams,          '{}'::jsonb),
        'courses',        COALESCE(v_courses,        '{}'::jsonb),
        'vigilancias',    COALESCE(v_vigilancias,    '{}'::jsonb),
        'evaluations',    COALESCE(v_evaluations,    '{}'::jsonb),
        'communications', COALESCE(v_communications, '{}'::jsonb),
        'notifications',  COALESCE(v_notifications,  '{}'::jsonb),
        'alerts',         COALESCE(v_alerts,         '[]'::jsonb),
        'alerts_total',   v_alerts_total_count,
        'upcoming_deadlines', COALESCE(v_deadlines,  '[]'::jsonb),
        'compliance',     COALESCE(v_compliance,     '{}'::jsonb)
    );
END;
$$;

ALTER FUNCTION public.get_dashboard_stats(uuid, date, text) OWNER TO postgres;
GRANT EXECUTE ON FUNCTION public.get_dashboard_stats(uuid, date, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_dashboard_stats(uuid, date, text) TO service_role;
