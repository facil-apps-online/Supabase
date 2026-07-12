-- =============================================
-- Connect dashboard: aggregated stats RPC
-- =============================================
-- Replaces the previous placeholder. Provides a single
-- SECURITY INVOKER RPC that returns all dashboard metrics
-- (employees, exams, courses, vigilancias, evaluations,
-- communications, notifications) for the tenant resolved
-- from the caller's JWT, scoped to the current month in
-- the provided timezone (defaults to America/Bogota).

DROP FUNCTION IF EXISTS public.get_dashboard_stats(uuid, date, text);

CREATE OR REPLACE FUNCTION public.get_dashboard_stats(
    p_tenant_id      uuid    DEFAULT NULL,
    p_reference_date date    DEFAULT NULL,
    p_timezone       text    DEFAULT 'America/Bogota'
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
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

    -- add derived trend percentage (avoid div-by-zero)
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

    -- 10. Notifications (read for the calling user; tenant-wide for admins)
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
        'notifications',  COALESCE(v_notifications,  '{}'::jsonb)
    );
END;
$$;

ALTER FUNCTION public.get_dashboard_stats(uuid, date, text) OWNER TO postgres;
GRANT EXECUTE ON FUNCTION public.get_dashboard_stats(uuid, date, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_dashboard_stats(uuid, date, text) TO service_role;
