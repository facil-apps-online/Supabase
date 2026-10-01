


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE TYPE "public"."activo_historial_evento" AS ENUM (
    'asignacion',
    'devolucion',
    'reparacion',
    'baja'
);


ALTER TYPE "public"."activo_historial_evento" OWNER TO "postgres";


CREATE TYPE "public"."app_role" AS ENUM (
    'super_admin',
    'tenant_admin',
    'user'
);


ALTER TYPE "public"."app_role" OWNER TO "postgres";


CREATE TYPE "public"."communication_status" AS ENUM (
    'borrador',
    'enviado',
    'leido'
);


ALTER TYPE "public"."communication_status" OWNER TO "postgres";


CREATE TYPE "public"."communication_type" AS ENUM (
    'circular',
    'memorando',
    'notificacion',
    'alerta'
);


ALTER TYPE "public"."communication_type" OWNER TO "postgres";


CREATE TYPE "public"."course_status" AS ENUM (
    'pendiente',
    'en_progreso',
    'completado',
    'vencido'
);


ALTER TYPE "public"."course_status" OWNER TO "postgres";


CREATE TYPE "public"."evaluation_status" AS ENUM (
    'pendiente',
    'en_proceso',
    'completada',
    'cancelada'
);


ALTER TYPE "public"."evaluation_status" OWNER TO "postgres";


CREATE TYPE "public"."event_status" AS ENUM (
    'borrador',
    'en_progreso',
    'completado',
    'cancelado'
);


ALTER TYPE "public"."event_status" OWNER TO "postgres";


CREATE TYPE "public"."exam_status" AS ENUM (
    'pendiente',
    'vigente',
    'vencido',
    'proximo_vencer'
);


ALTER TYPE "public"."exam_status" OWNER TO "postgres";


CREATE TYPE "public"."incapacidad_estado" AS ENUM (
    'registrada',
    'en_revision',
    'aprobada',
    'rechazada',
    'transcrita_nomina'
);


ALTER TYPE "public"."incapacidad_estado" OWNER TO "postgres";


CREATE TYPE "public"."incapacidad_origen" AS ENUM (
    'admin',
    'portal_empleado'
);


ALTER TYPE "public"."incapacidad_origen" OWNER TO "postgres";


CREATE TYPE "public"."permission_action" AS ENUM (
    'ver',
    'crear',
    'editar',
    'eliminar',
    'firmar',
    'aprobar'
);


ALTER TYPE "public"."permission_action" OWNER TO "postgres";


CREATE TYPE "public"."social_network" AS ENUM (
    'facebook',
    'twitter',
    'instagram',
    'linkedin',
    'youtube',
    'tiktok',
    'whatsapp',
    'website'
);


ALTER TYPE "public"."social_network" OWNER TO "postgres";


CREATE TYPE "public"."vigilancia_status" AS ENUM (
    'activa',
    'inactiva',
    'vencida'
);


ALTER TYPE "public"."vigilancia_status" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."calculate_evaluation_score"("_evaluation_id" "uuid") RETURNS numeric
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    _template_id uuid;
    _scale_min integer;
    _scale_max integer;
    _total_weight numeric := 0;
    _weighted_score numeric := 0;
    _section record;
    _criterion record;
    _response record;
    _criterion_score numeric;
    _section_score numeric;
    _section_count integer;
    _section_total numeric;
BEGIN
    -- Get template info
    SELECT e.template_id, t.scale_min, t.scale_max
    INTO _template_id, _scale_min, _scale_max
    FROM evaluations e
    JOIN evaluation_templates t ON t.id = e.template_id
    WHERE e.id = _evaluation_id;

    IF _template_id IS NULL THEN
        RETURN NULL;
    END IF;

    -- Loop through sections
    FOR _section IN
        SELECT id, weight FROM evaluation_template_sections
        WHERE template_id = _template_id ORDER BY sort_order
    LOOP
        _section_total := 0;
        _section_count := 0;

        FOR _criterion IN
            SELECT c.id, c.response_type, c.correct_answer, c.options
            FROM evaluation_template_criteria c
            WHERE c.section_id = _section.id ORDER BY c.sort_order
        LOOP
            SELECT * INTO _response
            FROM evaluation_responses
            WHERE evaluation_id = _evaluation_id AND criterion_id = _criterion.id;

            IF _response IS NOT NULL THEN
                _criterion_score := NULL;

                IF _criterion.response_type = 'scale' THEN
                    -- Normalize scale score to 0-1
                    IF _response.score IS NOT NULL AND _scale_max > _scale_min THEN
                        _criterion_score := (_response.score - _scale_min)::numeric / (_scale_max - _scale_min)::numeric;
                    END IF;

                ELSIF _criterion.response_type IN ('single_choice', 'yes_no') THEN
                    IF _criterion.correct_answer IS NOT NULL AND _criterion.correct_answer != '' THEN
                        _criterion_score := CASE WHEN _response.response_value = _criterion.correct_answer THEN 1.0 ELSE 0.0 END;
                    ELSIF _response.score IS NOT NULL THEN
                        _criterion_score := (_response.score - _scale_min)::numeric / (_scale_max - _scale_min)::numeric;
                    END IF;

                ELSIF _criterion.response_type = 'multiple_choice' THEN
                    IF _criterion.correct_answer IS NOT NULL AND _criterion.correct_answer != '' THEN
                        _criterion_score := CASE WHEN _response.response_value = _criterion.correct_answer THEN 1.0 ELSE 0.0 END;
                    ELSIF _response.score IS NOT NULL THEN
                        _criterion_score := (_response.score - _scale_min)::numeric / (_scale_max - _scale_min)::numeric;
                    END IF;

                ELSIF _criterion.response_type = 'open_text' THEN
                    IF _response.score IS NOT NULL THEN
                        _criterion_score := (_response.score - _scale_min)::numeric / (_scale_max - _scale_min)::numeric;
                    END IF;
                END IF;

                IF _criterion_score IS NOT NULL THEN
                    _section_total := _section_total + _criterion_score;
                    _section_count := _section_count + 1;
                END IF;
            END IF;
        END LOOP;

        IF _section_count > 0 THEN
            _section_score := _section_total / _section_count;
            _weighted_score := _weighted_score + (_section_score * _section.weight);
            _total_weight := _total_weight + _section.weight;
        END IF;
    END LOOP;

    IF _total_weight > 0 THEN
        -- Return score on the template's scale
        RETURN ROUND(_scale_min + ((_weighted_score / _total_weight) * (_scale_max - _scale_min)), 2);
    END IF;

    RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."calculate_evaluation_score"("_evaluation_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."check_event_tenant"("p_event_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.events
    WHERE id = p_event_id
      AND (tenant_id = public.get_user_tenant_id(auth.uid()) OR public.is_super_admin(auth.uid()))
  );
$$;


ALTER FUNCTION "public"."check_event_tenant"("p_event_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."check_user_exists_in_auth_rpc"("p_email" "text") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  user_exists boolean;
BEGIN
  SELECT EXISTS (SELECT 1 FROM auth.users WHERE email = p_email) INTO user_exists;
  RETURN user_exists;
END;
$$;


ALTER FUNCTION "public"."check_user_exists_in_auth_rpc"("p_email" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."count_active_employees_for_billing"("p_tenant_id" "uuid") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_count integer;
BEGIN
    SELECT count(*)::integer
    INTO v_count
    FROM public.employees
    WHERE tenant_id = p_tenant_id
      AND (
          termination_date IS NULL
          OR date_trunc('month', termination_date) = date_trunc('month', current_date)
      );
      
    RETURN v_count;
END;
$$;


ALTER FUNCTION "public"."count_active_employees_for_billing"("p_tenant_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_tenant_with_admin"("p_tenant_id" "uuid", "p_user_id" "uuid", "p_platform_id" "uuid", "p_tenant_name" "text", "p_country_id" "text" DEFAULT NULL::"text", "p_email" "text" DEFAULT NULL::"text", "p_currency_id" "uuid" DEFAULT NULL::"uuid", "p_timezone" "text" DEFAULT NULL::"text", "p_phone" "text" DEFAULT NULL::"text", "p_address" "text" DEFAULT NULL::"text", "p_website" "text" DEFAULT NULL::"text", "p_latitude" numeric DEFAULT NULL::numeric, "p_longitude" numeric DEFAULT NULL::numeric, "p_whatsapp_phone" "text" DEFAULT NULL::"text", "p_legal_name" "text" DEFAULT NULL::"text", "p_tax_id" "text" DEFAULT NULL::"text", "p_einvoicing_email" "text" DEFAULT NULL::"text", "p_physical_address_line1" "text" DEFAULT NULL::"text", "p_physical_address_line2" "text" DEFAULT NULL::"text", "p_physical_city" "text" DEFAULT NULL::"text", "p_physical_state" "text" DEFAULT NULL::"text", "p_physical_postal_code" "text" DEFAULT NULL::"text", "p_default_language_code" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_role_id UUID;
    v_tenant_exists BOOLEAN;
    v_country_uuid UUID;
BEGIN
    -- 1. Validar y convertir country_id
    BEGIN
        v_country_uuid := p_country_id::UUID;
    EXCEPTION WHEN OTHERS THEN
        v_country_uuid := NULL;
    END;

    -- 2. Verificar si el tenant ya existe
    SELECT EXISTS(SELECT 1 FROM public.tenants WHERE id = p_tenant_id AND platform_id = p_platform_id) INTO v_tenant_exists;
    
    IF NOT v_tenant_exists THEN
        INSERT INTO public.tenants (
            id,
            platform_id,
            name,
            country_id,
            contact_email,
            contact_phone,
            whatsapp_phone,
            billing_address,
            website,
            latitude,
            longitude,
            default_currency_id,
            default_timezone,
            subscription_status,
            is_active,
            legal_name,
            tax_id,
            einvoicing_email,
            physical_address_line1,
            physical_address_line2,
            physical_city,
            physical_state,
            physical_postal_code,
            default_language_code
        ) VALUES (
            p_tenant_id,
            p_platform_id,
            p_tenant_name,
            v_country_uuid,
            p_email,
            p_phone,
            p_whatsapp_phone,
            p_address,
            p_website,
            p_latitude,
            p_longitude,
            p_currency_id,
            p_timezone,
            'trial',
            true,
            p_legal_name,
            p_tax_id,
            p_einvoicing_email,
            p_physical_address_line1,
            p_physical_address_line2,
            p_physical_city,
            p_physical_state,
            p_physical_postal_code,
            p_default_language_code
        );
    END IF;

    -- 3. Crear Perfil de Usuario si no existe
    IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE user_id = p_user_id) THEN
        INSERT INTO public.profiles (user_id, email, tenant_id, is_super_admin)
        VALUES (p_user_id, p_email, p_tenant_id, false);
    END IF;

    -- 4. Obtener o Crear Rol Administrador para este Tenant
    SELECT id INTO v_role_id FROM public.roles WHERE tenant_id = p_tenant_id AND name = 'Administrador' LIMIT 1;
    IF v_role_id IS NULL THEN
        INSERT INTO public.roles (tenant_id, name, description, is_system)
        VALUES (p_tenant_id, 'Administrador', 'Administrador del sistema', true)
        RETURNING id INTO v_role_id;
    END IF;

    -- 5. Asignar Rol al Usuario
    IF NOT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = p_user_id AND role_id = v_role_id) THEN
        INSERT INTO public.user_roles (user_id, role_id)
        VALUES (p_user_id, v_role_id);
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'tenant_id', p_tenant_id,
        'user_id', p_user_id
    );
END;
$$;


ALTER FUNCTION "public"."create_tenant_with_admin"("p_tenant_id" "uuid", "p_user_id" "uuid", "p_platform_id" "uuid", "p_tenant_name" "text", "p_country_id" "text", "p_email" "text", "p_currency_id" "uuid", "p_timezone" "text", "p_phone" "text", "p_address" "text", "p_website" "text", "p_latitude" numeric, "p_longitude" numeric, "p_whatsapp_phone" "text", "p_legal_name" "text", "p_tax_id" "text", "p_einvoicing_email" "text", "p_physical_address_line1" "text", "p_physical_address_line2" "text", "p_physical_city" "text", "p_physical_state" "text", "p_physical_postal_code" "text", "p_default_language_code" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_current_employee_id"() RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
    SELECT employee_id FROM public.employee_portal_accounts
    WHERE user_id = auth.uid() AND status = 'active' LIMIT 1
$$;


ALTER FUNCTION "public"."get_current_employee_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_dashboard_stats"("p_tenant_id" "uuid" DEFAULT NULL::"uuid", "p_reference_date" "date" DEFAULT NULL::"date", "p_timezone" "text" DEFAULT 'America/Bogota'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
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
        'vencido',        COUNT(*) FILTER (WHERE status = 'vencido' OR (status = 'pendiente' AND scheduled_date < v_reference_date)),
        'proximo_vencer', COUNT(*) FILTER (WHERE status = 'proximo_vencer' OR (status = 'pendiente' AND scheduled_date >= v_reference_date AND scheduled_date <= v_reference_date + interval '30 days')),
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
           OR (status = 'pendiente' AND scheduled_date < v_reference_date)
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
                    (1,  'urgent',  'Exámenes vencidos',
                            CASE WHEN v_alert_exams_expired = 1
                                 THEN '1 examen con fecha vencida'
                                 ELSE v_alert_exams_expired || ' exámenes con fecha vencida'
                            END,
                            v_alert_exams_expired),
                    (2,  'urgent',  'Cursos por renovar',
                            CASE WHEN v_alert_courses_expiring_30d = 1
                                 THEN '1 certificación próxima a vencer en 30 días'
                                 ELSE v_alert_courses_expiring_30d || ' certificaciones próximas a vencer en 30 días'
                            END,
                            v_alert_courses_expiring_30d),
                    (3,  'warning', 'Evaluaciones vencidas',
                            CASE WHEN v_alert_evaluations_overdue = 1
                                 THEN '1 evaluación sin completar después de su fecha'
                                 ELSE v_alert_evaluations_overdue || ' evaluaciones sin completar después de su fecha'
                            END,
                            v_alert_evaluations_overdue),
                    (4,  'warning', 'Firmas pendientes',
                            CASE WHEN v_alert_event_signatures = 1
                                 THEN '1 empleado sin firmar en eventos recientes'
                                 ELSE v_alert_event_signatures || ' empleados sin firmar en eventos recientes'
                            END,
                            v_alert_event_signatures),
                    (5,  'warning', 'COPASST próximo a vencer',
                            CASE WHEN v_alert_copasst_expiring_15d = 1
                                 THEN 'La vigencia del comité termina en menos de 15 días'
                                 ELSE v_alert_copasst_expiring_15d || ' comités terminan su vigencia en menos de 15 días'
                            END,
                            v_alert_copasst_expiring_15d),
                    (6,  'info',    'Dotación programada',
                            CASE WHEN v_alert_dotacion_next_7d = 1
                                 THEN '1 entrega de dotación en los próximos 7 días'
                                 ELSE v_alert_dotacion_next_7d || ' entregas de dotación en los próximos 7 días'
                            END,
                            v_alert_dotacion_next_7d),
                    (7,  'info',    'Incapacidades en revisión',
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
                        'title',    'Examen ' || COALESCE(e.exam_type, 'médico') || ' - ' ||
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
                        'title',    'Renovación ' || c.name,
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
                    'module',     'exámenes',
                    'scheduled',  exam_stats.scheduled,
                    'completed',  exam_stats.completed,
                    'percentage', CASE WHEN exam_stats.scheduled > 0
                                       THEN ROUND((exam_stats.completed::numeric / exam_stats.scheduled) * 100)::int
                                       ELSE NULL END
                ) AS row,
                'exámenes'::text AS module_key
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
                    'module',     'dotación',
                    'scheduled',  dotacion_stats.scheduled,
                    'completed',  dotacion_stats.completed,
                    'percentage', CASE WHEN dotacion_stats.scheduled > 0
                                       THEN ROUND((dotacion_stats.completed::numeric / dotacion_stats.scheduled) * 100)::int
                                       ELSE NULL END
                ),
                'dotación'::text
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


ALTER FUNCTION "public"."get_dashboard_stats"("p_tenant_id" "uuid", "p_reference_date" "date", "p_timezone" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_nexuhr_storage_usage"("p_tenant_id" "uuid") RETURNS TABLE("category" "text", "size" bigint)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."get_nexuhr_storage_usage"("p_tenant_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_portal_permissions"("p_tenant_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_settings JSONB;
BEGIN
  SELECT settings_data INTO v_settings
  FROM public.tenant_settings
  WHERE tenant_id = p_tenant_id
    AND setting_key = 'portal'
  LIMIT 1;

  RETURN jsonb_build_object(
    'can_change_photo', COALESCE((v_settings->>'can_change_photo')::boolean, true),
    'can_change_data',  COALESCE((v_settings->>'can_change_data')::boolean, true)
  );
END;
$$;


ALTER FUNCTION "public"."get_portal_permissions"("p_tenant_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_tenant_by_portal_slug"("p_slug" "text") RETURNS TABLE("tenant_id" "uuid", "logo_url" "text", "tenant_name" "text")
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
    RETURN QUERY
    SELECT t.id, t.logo_url, t.name
    FROM public.tenant_settings ts
    JOIN public.tenants t ON t.id = ts.tenant_id AND t.platform_id = ts.platform_id
    WHERE ts.setting_key = 'portal'
      AND ts.settings_data->>'slug' = p_slug
    LIMIT 1;
END;
$$;


ALTER FUNCTION "public"."get_tenant_by_portal_slug"("p_slug" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_user_notification_preferences"("_user_id" "uuid") RETURNS TABLE("receive_summary" boolean, "summary_frequency" "text", "email_enabled" boolean, "in_app_enabled" boolean)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    _tenant_id UUID;
BEGIN
    -- Obtener tenant del usuario
    SELECT tenant_id INTO _tenant_id FROM profiles WHERE user_id = _user_id LIMIT 1;
    
    -- Primero buscar preferencias del usuario
    RETURN QUERY
    SELECT np.receive_summary, np.summary_frequency, np.email_enabled, np.in_app_enabled
    FROM notification_preferences np
    WHERE np.user_id = _user_id AND np.tenant_id = _tenant_id
    LIMIT 1;
    
    IF NOT FOUND THEN
        -- Si no hay preferencias de usuario, buscar por rol
        RETURN QUERY
        SELECT rnp.receive_summary, rnp.summary_frequency, rnp.email_enabled, rnp.in_app_enabled
        FROM role_notification_preferences rnp
        INNER JOIN user_roles ur ON ur.role_id = rnp.role_id
        WHERE ur.user_id = _user_id AND rnp.tenant_id = _tenant_id
        LIMIT 1;
    END IF;
    
    IF NOT FOUND THEN
        -- Valores por defecto
        RETURN QUERY SELECT false, 'daily'::TEXT, true, true;
    END IF;
END;
$$;


ALTER FUNCTION "public"."get_user_notification_preferences"("_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_user_tenant_id"("_user_id" "uuid") RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
    SELECT tenant_id FROM public.profiles WHERE user_id = _user_id LIMIT 1
$$;


ALTER FUNCTION "public"."get_user_tenant_id"("_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."has_permission"("_user_id" "uuid", "_module_code" "text", "_action" "public"."permission_action") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
    SELECT EXISTS (
        -- Super admin has all permissions
        SELECT 1 FROM public.profiles WHERE user_id = _user_id AND is_super_admin = true
        UNION ALL
        -- Check role permissions
        SELECT 1 FROM public.user_roles ur
        JOIN public.role_permissions rp ON ur.role_id = rp.role_id
        JOIN public.permissions p ON rp.permission_id = p.id
        JOIN public.modules m ON p.module_id = m.id
        WHERE ur.user_id = _user_id AND m.code = _module_code AND p.action = _action
        UNION ALL
        -- Check individual permissions (granted)
        SELECT 1 FROM public.user_permissions up
        JOIN public.permissions p ON up.permission_id = p.id
        JOIN public.modules m ON p.module_id = m.id
        WHERE up.user_id = _user_id AND m.code = _module_code AND p.action = _action AND up.granted = true
    )
    AND NOT EXISTS (
        -- Check individual permissions (revoked)
        SELECT 1 FROM public.user_permissions up
        JOIN public.permissions p ON up.permission_id = p.id
        JOIN public.modules m ON p.module_id = m.id
        WHERE up.user_id = _user_id AND m.code = _module_code AND p.action = _action AND up.granted = false
    )
$$;


ALTER FUNCTION "public"."has_permission"("_user_id" "uuid", "_module_code" "text", "_action" "public"."permission_action") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."has_role"("_user_id" "uuid", "_role" "public"."app_role") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.profiles
        WHERE user_id = _user_id
        AND (
            (_role = 'super_admin' AND is_super_admin = true)
            OR EXISTS (
                SELECT 1 FROM public.user_roles ur
                JOIN public.roles r ON ur.role_id = r.id
                WHERE ur.user_id = _user_id
            )
        )
    )
$$;


ALTER FUNCTION "public"."has_role"("_user_id" "uuid", "_role" "public"."app_role") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_super_admin"("_user_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.profiles
        WHERE user_id = _user_id AND is_super_admin = true
    )
$$;


ALTER FUNCTION "public"."is_super_admin"("_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."portal_account_mark_password_changed"("p_account_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
    UPDATE public.employee_portal_accounts
    SET must_change_password = false
    WHERE id = p_account_id AND user_id = auth.uid();
END;
$$;


ALTER FUNCTION "public"."portal_account_mark_password_changed"("p_account_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."resolve_employee_login"("p_documento" "text", "p_tenant_slug" "text" DEFAULT NULL::"text") RETURNS TABLE("synthetic_email" "text", "must_change_password" boolean, "tenant_slug" "text")
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
    RETURN QUERY
    SELECT epa.synthetic_email, epa.must_change_password, t.slug
    FROM public.employee_portal_accounts epa
    JOIN public.employees e ON e.id = epa.employee_id
    JOIN public.tenants t ON t.id = epa.tenant_id
    WHERE e.document_number = p_documento
      AND epa.status = 'active'
      AND (p_tenant_slug IS NULL OR t.slug = p_tenant_slug)
    LIMIT 1;
END;
$$;


ALTER FUNCTION "public"."resolve_employee_login"("p_documento" "text", "p_tenant_slug" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."revoke_portal_on_retire"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
    IF (NEW.active = false OR NEW.termination_date IS NOT NULL)
       AND (OLD.active IS DISTINCT FROM NEW.active OR OLD.termination_date IS DISTINCT FROM NEW.termination_date) THEN
        UPDATE public.employee_portal_accounts
        SET status = 'revoked', revoked_at = now(),
            revoked_reason = COALESCE(revoked_reason, 'Retiro del empleado')
        WHERE employee_id = NEW.id AND status = 'active';
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."revoke_portal_on_retire"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_super_admin_on_role_change"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    role_is_admin BOOLEAN;
BEGIN
    IF TG_OP = 'INSERT' THEN
        -- Check if the assigned role is the system "Administrador" role
        SELECT is_system INTO role_is_admin FROM public.roles WHERE id = NEW.role_id;
        
        IF role_is_admin = true THEN
            UPDATE public.profiles SET is_super_admin = true WHERE user_id = NEW.user_id;
        END IF;
        RETURN NEW;
        
    ELSIF TG_OP = 'DELETE' THEN
        -- Check if the removed role is the system "Administrador" role
        SELECT is_system INTO role_is_admin FROM public.roles WHERE id = OLD.role_id;
        
        IF role_is_admin = true THEN
            -- Only set to false if user has no other admin roles
            IF NOT EXISTS (
                SELECT 1 FROM public.user_roles ur
                JOIN public.roles r ON ur.role_id = r.id
                WHERE ur.user_id = OLD.user_id AND r.is_system = true AND ur.id != OLD.id
            ) THEN
                UPDATE public.profiles SET is_super_admin = false WHERE user_id = OLD.user_id;
            END IF;
        END IF;
        RETURN OLD;
    END IF;
    
    RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."sync_super_admin_on_role_change"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_updated_at_column"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_updated_at_column"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."activo_fijo_estados" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid",
    "name" "text" NOT NULL,
    "description" "text",
    "is_standard" boolean DEFAULT false NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."activo_fijo_estados" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."activo_fijo_marcas" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid",
    "name" "text" NOT NULL,
    "is_standard" boolean DEFAULT false NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."activo_fijo_marcas" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."activo_fijo_tipos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid",
    "name" "text" NOT NULL,
    "description" "text",
    "is_standard" boolean DEFAULT false NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."activo_fijo_tipos" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."activos_fijos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "modelo" "text" NOT NULL,
    "numero_serie" "text",
    "empleado_asignado_id" "uuid",
    "fecha_asignacion" timestamp with time zone,
    "fecha_compra" "date",
    "valor" numeric(12,2),
    "notas" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "tipo_id" "uuid" NOT NULL,
    "estado_id" "uuid" NOT NULL,
    "marca_id" "uuid"
);


ALTER TABLE "public"."activos_fijos" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."activos_fijos_historial" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "activo_fijo_id" "uuid" NOT NULL,
    "empleado_id" "uuid",
    "tipo_evento" "public"."activo_historial_evento" NOT NULL,
    "fecha_evento" timestamp with time zone DEFAULT "now"() NOT NULL,
    "descripcion" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."activos_fijos_historial" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."annual_parameters" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "year" integer NOT NULL,
    "minimum_wage" numeric DEFAULT 0 NOT NULL,
    "transport_allowance" numeric DEFAULT 0 NOT NULL,
    "uvt_value" numeric DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "created_by" "uuid"
);


ALTER TABLE "public"."annual_parameters" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."audit_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid",
    "user_id" "uuid",
    "action" "text" NOT NULL,
    "table_name" "text" NOT NULL,
    "record_id" "uuid",
    "old_data" "jsonb",
    "new_data" "jsonb",
    "ip_address" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."audit_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."certificate_templates" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "template_type" "text" DEFAULT 'laboral'::"text" NOT NULL,
    "content_template" "text" NOT NULL,
    "active" boolean DEFAULT true,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."certificate_templates" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."committee_meetings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "committee_id" "uuid" NOT NULL,
    "meeting_date" timestamp with time zone NOT NULL,
    "location" "text",
    "agenda" "text",
    "minutes" "text",
    "attendees" "uuid"[],
    "document_url" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."committee_meetings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."committee_members" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "committee_id" "uuid" NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "role" "text" NOT NULL,
    "start_date" "date",
    "end_date" "date",
    "active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."committee_members" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."committee_roles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "is_standard" boolean DEFAULT false,
    "tenant_id" "uuid",
    "active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."committee_roles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."committees" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "start_date" "date" NOT NULL,
    "end_date" "date",
    "active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."committees" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."communication_reads" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "communication_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "read_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."communication_reads" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."communications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "communication_type" "public"."communication_type" NOT NULL,
    "subject" "text" NOT NULL,
    "content" "text" NOT NULL,
    "priority" "text" DEFAULT 'normal'::"text",
    "recipients" "uuid"[],
    "attachment_urls" "text"[],
    "status" "public"."communication_status" DEFAULT 'borrador'::"public"."communication_status",
    "sent_at" timestamp with time zone,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."communications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."course_providers" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "active" boolean DEFAULT true,
    "is_standard" boolean DEFAULT false,
    "tenant_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."course_providers" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."course_types" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "active" boolean DEFAULT true,
    "is_standard" boolean DEFAULT false,
    "tenant_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."course_types" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."courses" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "course_name" "text" NOT NULL,
    "provider" "text",
    "start_date" "date" NOT NULL,
    "end_date" "date",
    "duration_hours" integer,
    "expiry_date" "date",
    "certificate_url" "text",
    "status" "public"."course_status" DEFAULT 'pendiente'::"public"."course_status",
    "grade" numeric(5,2),
    "observations" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "certificate_size" integer
);


ALTER TABLE "public"."courses" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."departments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."departments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."distribution_list_members" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "list_id" "uuid" NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."distribution_list_members" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."distribution_lists" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "list_type" "text" DEFAULT 'personalizada'::"text" NOT NULL,
    "target_value" "text",
    "active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "distribution_lists_list_type_check" CHECK (("list_type" = ANY (ARRAY['general'::"text", 'cargo'::"text", 'departamento'::"text", 'personalizada'::"text"])))
);


ALTER TABLE "public"."distribution_lists" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."document_types" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid",
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "is_standard" boolean DEFAULT false,
    CONSTRAINT "document_types_standard_or_tenant" CHECK (((("is_standard" = true) AND ("tenant_id" IS NULL)) OR (("is_standard" = false) AND ("tenant_id" IS NOT NULL))))
);


ALTER TABLE "public"."document_types" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."dotacion" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "item_name" "text" NOT NULL,
    "item_type" "text",
    "quantity" integer DEFAULT 1,
    "delivery_date" "date" NOT NULL,
    "expiry_date" "date",
    "size" "text",
    "signature_url" "text",
    "observations" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."dotacion" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."dotacion_types" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "active" boolean DEFAULT true,
    "is_standard" boolean DEFAULT false,
    "tenant_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."dotacion_types" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."employee_activity_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "action" "text" NOT NULL,
    "entity_type" "text",
    "entity_id" "uuid",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "ip_address" "text",
    "user_agent" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."employee_activity_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."employee_contracts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "contract_type" "text" DEFAULT 'indefinido'::"text" NOT NULL,
    "start_date" "date" NOT NULL,
    "end_date" "date",
    "base_salary" numeric DEFAULT 0 NOT NULL,
    "currency" "text" DEFAULT 'COP'::"text" NOT NULL,
    "payment_frequency" "text" DEFAULT 'mensual'::"text" NOT NULL,
    "position" "text",
    "department" "text",
    "work_hours_per_week" integer DEFAULT 48,
    "active" boolean DEFAULT true,
    "observations" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."employee_contracts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."employee_photos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "platform_id" "uuid" NOT NULL,
    "google_drive_file_id" "text" NOT NULL,
    "file_name" "text",
    "file_size" bigint,
    "mime_type" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."employee_photos" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."employee_portal_accounts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "user_id" "uuid",
    "synthetic_email" "text" NOT NULL,
    "must_change_password" boolean DEFAULT true NOT NULL,
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "activated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "last_login_at" timestamp with time zone,
    "revoked_at" timestamp with time zone,
    "revoked_reason" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "employee_portal_accounts_status_check" CHECK (("status" = ANY (ARRAY['active'::"text", 'revoked'::"text"])))
);


ALTER TABLE "public"."employee_portal_accounts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."employees" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "document_type" "text" DEFAULT 'CC'::"text" NOT NULL,
    "document_number" "text" NOT NULL,
    "first_name" "text" NOT NULL,
    "last_name" "text" NOT NULL,
    "email" "text",
    "phone" "text",
    "position" "text",
    "department" "text",
    "hire_date" "date",
    "birth_date" "date",
    "address" "text",
    "city" "text",
    "emergency_contact" "text",
    "emergency_phone" "text",
    "photo_url" "text",
    "active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "supervisor_id" "uuid",
    "termination_date" "date",
    "photo_size" integer
);


ALTER TABLE "public"."employees" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."evaluation_responses" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "evaluation_id" "uuid" NOT NULL,
    "criterion_id" "uuid" NOT NULL,
    "score" numeric(5,2),
    "comments" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "response_value" "text"
);


ALTER TABLE "public"."evaluation_responses" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."evaluation_template_criteria" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "section_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "sort_order" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "response_type" "text" DEFAULT 'scale'::"text" NOT NULL,
    "options" "jsonb",
    "correct_answer" "text"
);


ALTER TABLE "public"."evaluation_template_criteria" OWNER TO "postgres";


COMMENT ON COLUMN "public"."evaluation_template_criteria"."response_type" IS 'Type: scale, multiple_choice, single_choice, yes_no, open_text';



COMMENT ON COLUMN "public"."evaluation_template_criteria"."options" IS 'JSON array of option labels for choice-type questions, e.g. ["Opción A","Opción B"]';



COMMENT ON COLUMN "public"."evaluation_template_criteria"."correct_answer" IS 'Expected correct answer for auto-grading (optional)';



CREATE TABLE IF NOT EXISTS "public"."evaluation_template_sections" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "template_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "weight" numeric(5,2) DEFAULT 100 NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."evaluation_template_sections" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."evaluation_templates" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "evaluation_type" "text" NOT NULL,
    "description" "text",
    "scale_min" integer DEFAULT 1 NOT NULL,
    "scale_max" integer DEFAULT 5 NOT NULL,
    "periodicity" "text" DEFAULT 'anual'::"text",
    "is_anonymous" boolean DEFAULT false,
    "active" boolean DEFAULT true,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "assignment_mode" "text" DEFAULT 'individual'::"text" NOT NULL
);


ALTER TABLE "public"."evaluation_templates" OWNER TO "postgres";


COMMENT ON COLUMN "public"."evaluation_templates"."assignment_mode" IS 'Modes: individual, bulk, department, self, 360';



CREATE TABLE IF NOT EXISTS "public"."evaluation_types" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "active" boolean DEFAULT true,
    "is_standard" boolean DEFAULT false,
    "tenant_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."evaluation_types" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."evaluations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "template_id" "uuid" NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "evaluator_id" "uuid",
    "period" "text" NOT NULL,
    "evaluation_date" "date" NOT NULL,
    "overall_score" numeric(5,2),
    "status" "public"."evaluation_status" DEFAULT 'pendiente'::"public"."evaluation_status",
    "comments" "text",
    "strengths" "text",
    "areas_improvement" "text",
    "action_plan" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."evaluations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."event_participants" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_id" "uuid" NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "signed" boolean DEFAULT false,
    "signature_url" "text",
    "signed_at" timestamp with time zone,
    "invited_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."event_participants" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."event_types" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "active" boolean DEFAULT true,
    "is_standard" boolean DEFAULT false,
    "tenant_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."event_types" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "event_type" "text" NOT NULL,
    "event_date" "date" NOT NULL,
    "description" "text",
    "location" "text",
    "status" "public"."event_status" DEFAULT 'borrador'::"public"."event_status",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."evidences" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "module" "text" NOT NULL,
    "record_id" "uuid" NOT NULL,
    "employee_id" "uuid",
    "file_url" "text" NOT NULL,
    "file_name" "text" NOT NULL,
    "file_type" "text",
    "file_size" integer,
    "description" "text",
    "uploaded_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "uploaded_by_employee_id" "uuid"
);


ALTER TABLE "public"."evidences" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."exam_types" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "active" boolean DEFAULT true,
    "is_standard" boolean DEFAULT false,
    "tenant_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "exam_types_standard_or_tenant" CHECK (((("is_standard" = true) AND ("tenant_id" IS NULL)) OR (("is_standard" = false) AND ("tenant_id" IS NOT NULL))))
);


ALTER TABLE "public"."exam_types" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."exams" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "exam_type" "text" NOT NULL,
    "exam_date" "date" NOT NULL,
    "expiry_date" "date",
    "result" "text",
    "observations" "text",
    "document_url" "text",
    "status" "public"."exam_status" DEFAULT 'pendiente'::"public"."exam_status",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "entity" "text",
    "scheduled_date" "date",
    "document_size" integer
);


ALTER TABLE "public"."exams" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."incapacidad_types" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid",
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "is_standard" boolean DEFAULT false NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."incapacidad_types" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."incapacidades" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "tipo" "text" NOT NULL,
    "fecha_inicio" "date" NOT NULL,
    "fecha_fin" "date" NOT NULL,
    "dias" integer NOT NULL,
    "diagnostico" "text",
    "codigo_cie" "text",
    "entidad" "text",
    "numero_radicado" "text",
    "prorroga_de" "uuid",
    "estado" "public"."incapacidad_estado" DEFAULT 'registrada'::"public"."incapacidad_estado" NOT NULL,
    "origen" "public"."incapacidad_origen" DEFAULT 'admin'::"public"."incapacidad_origen" NOT NULL,
    "documento_url" "text",
    "notas_internas" "text",
    "created_by" "uuid",
    "reviewed_by" "uuid",
    "reviewed_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "documento_size" integer
);


ALTER TABLE "public"."incapacidades" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."modules" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "icon" "text",
    "active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."modules" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."notification_preferences" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "receive_summary" boolean DEFAULT false,
    "summary_frequency" "text" DEFAULT 'daily'::"text",
    "email_enabled" boolean DEFAULT true,
    "in_app_enabled" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."notification_preferences" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."notifications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "user_id" "uuid",
    "title" "text" NOT NULL,
    "message" "text" NOT NULL,
    "type" "text" DEFAULT 'info'::"text",
    "link" "text",
    "read" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "employee_id" "uuid"
);


ALTER TABLE "public"."notifications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."payroll_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "period_id" "uuid" NOT NULL,
    "concept" "text" NOT NULL,
    "type" "text" NOT NULL,
    "value" numeric DEFAULT 0 NOT NULL,
    "payment_date" "date",
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "created_by" "uuid",
    CONSTRAINT "payroll_items_type_check" CHECK (("type" = ANY (ARRAY['DEV'::"text", 'DED'::"text"])))
);


ALTER TABLE "public"."payroll_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."payroll_periods" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "start_date" "date" NOT NULL,
    "end_date" "date" NOT NULL,
    "payment_date" "date",
    "frequency" "text" DEFAULT 'mensual'::"text" NOT NULL,
    "status" "text" DEFAULT 'abierto'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "created_by" "uuid"
);


ALTER TABLE "public"."payroll_periods" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."payroll_records" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "contract_id" "uuid",
    "base_salary" numeric DEFAULT 0 NOT NULL,
    "transport_allowance" numeric DEFAULT 0,
    "overtime" numeric DEFAULT 0,
    "bonuses" numeric DEFAULT 0,
    "commissions" numeric DEFAULT 0,
    "other_earnings" numeric DEFAULT 0,
    "health_deduction" numeric DEFAULT 0,
    "pension_deduction" numeric DEFAULT 0,
    "tax_deduction" numeric DEFAULT 0,
    "other_deductions" numeric DEFAULT 0,
    "total_earnings" numeric GENERATED ALWAYS AS (((((("base_salary" + "transport_allowance") + "overtime") + "bonuses") + "commissions") + "other_earnings")) STORED,
    "total_deductions" numeric GENERATED ALWAYS AS (((("health_deduction" + "pension_deduction") + "tax_deduction") + "other_deductions")) STORED,
    "net_pay" numeric GENERATED ALWAYS AS (((((((((("base_salary" + "transport_allowance") + "overtime") + "bonuses") + "commissions") + "other_earnings") - "health_deduction") - "pension_deduction") - "tax_deduction") - "other_deductions")) STORED,
    "payment_date" "date",
    "status" "text" DEFAULT 'borrador'::"text" NOT NULL,
    "notes" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "period_id" "uuid"
);


ALTER TABLE "public"."payroll_records" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."pending_summary_notifications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "notification_type" "text" NOT NULL,
    "title" "text" NOT NULL,
    "message" "text" NOT NULL,
    "link" "text",
    "related_entity_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "processed" boolean DEFAULT false,
    "processed_at" timestamp with time zone
);


ALTER TABLE "public"."pending_summary_notifications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."permissions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "module_id" "uuid" NOT NULL,
    "action" "public"."permission_action" NOT NULL,
    "description" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."permissions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."positions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."positions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "tenant_id" "uuid",
    "first_name" "text",
    "last_name" "text",
    "email" "text" NOT NULL,
    "phone" "text",
    "avatar_url" "text",
    "is_super_admin" boolean DEFAULT false,
    "active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."regulation_acknowledgments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "regulation_id" "uuid" NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "acknowledged_at" timestamp with time zone,
    "signature_url" "text",
    "ip_address" "text",
    "status" "text" DEFAULT 'pendiente'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."regulation_acknowledgments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."regulations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "version" "text" DEFAULT '1.0'::"text" NOT NULL,
    "content_type" "text" DEFAULT 'text'::"text" NOT NULL,
    "content_text" "text",
    "document_url" "text",
    "effective_date" "date" DEFAULT CURRENT_DATE NOT NULL,
    "status" "text" DEFAULT 'borrador'::"text" NOT NULL,
    "requires_signature" boolean DEFAULT true,
    "published_at" timestamp with time zone,
    "published_by" "uuid",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "document_size" integer
);


ALTER TABLE "public"."regulations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."role_notification_preferences" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "role_id" "uuid" NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "receive_summary" boolean DEFAULT false,
    "summary_frequency" "text" DEFAULT 'daily'::"text",
    "email_enabled" boolean DEFAULT true,
    "in_app_enabled" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."role_notification_preferences" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."role_permissions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "role_id" "uuid" NOT NULL,
    "permission_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."role_permissions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."roles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "is_system" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."roles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."signatures" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "module" "text" NOT NULL,
    "record_id" "uuid" NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "signed_by" "uuid",
    "signature_url" "text",
    "signed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "watermark_text" "text",
    "method" "text" DEFAULT 'canvas'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "file_size" integer,
    CONSTRAINT "signatures_method_check" CHECK (("method" = ANY (ARRAY['canvas'::"text", 'admin_confirmation'::"text"])))
);


ALTER TABLE "public"."signatures" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tenant_settings" (
    "tenant_id" "uuid" NOT NULL,
    "settings_data" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "platform_id" "uuid" NOT NULL,
    "setting_key" "text" DEFAULT 'general'::"text" NOT NULL
);


ALTER TABLE "public"."tenant_settings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tenant_social_networks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "network" "public"."social_network" NOT NULL,
    "url" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone,
    "platform_id" "uuid" NOT NULL,
    CONSTRAINT "tenant_social_networks_url_check" CHECK (("url" ~* '^https?://'::"text"))
);


ALTER TABLE "public"."tenant_social_networks" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tenants" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "subscription_status" "text" DEFAULT 'trial'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "default_language_code" "text",
    "default_currency_id" "uuid",
    "default_timezone" "text",
    "contact_person" "text",
    "contact_email" "text",
    "contact_phone" "text",
    "country_id" "uuid",
    "is_active" boolean DEFAULT true,
    "logo_url" "text",
    "notes" "text",
    "legal_name" "text",
    "tax_id" "text",
    "billing_address" "text",
    "website" "text",
    "whatsapp_phone" "text",
    "einvoicing_email" "text",
    "physical_address_line1" "text",
    "physical_address_line2" "text",
    "physical_city" "text",
    "physical_state" "text",
    "physical_postal_code" "text",
    "latitude" numeric(10,7),
    "longitude" numeric(10,7),
    "commercial_email" "text",
    "integrations_mode" "text" DEFAULT 'production'::"text" NOT NULL,
    "is_system_owner" boolean DEFAULT false NOT NULL,
    "platform_id" "uuid" NOT NULL,
    "primary_color" "text",
    "secondary_color" "text",
    "slug" "text",
    "description" "text",
    "logo_file_size" bigint DEFAULT 0,
    "logo_size" integer,
    CONSTRAINT "tenants_subscription_status_check" CHECK (("subscription_status" = ANY (ARRAY['trial'::"text", 'active'::"text", 'inactive'::"text", 'expired'::"text", 'canceled'::"text", 'grace_period'::"text"]))),
    CONSTRAINT "valid_slug_format" CHECK ((("slug" IS NULL) OR (("slug" ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'::"text") AND ("length"("slug") > 2))))
);


ALTER TABLE "public"."tenants" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_permissions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "permission_id" "uuid" NOT NULL,
    "granted" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."user_permissions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_roles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "role_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."user_roles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."vigilancia_types" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "active" boolean DEFAULT true,
    "tenant_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "is_standard" boolean DEFAULT false
);


ALTER TABLE "public"."vigilancia_types" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."vigilancias" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "vigilancia_type" "text" NOT NULL,
    "diagnosis" "text",
    "start_date" "date" NOT NULL,
    "end_date" "date",
    "follow_up_date" "date",
    "recommendations" "text",
    "restrictions" "text",
    "status" "public"."vigilancia_status" DEFAULT 'activa'::"public"."vigilancia_status",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."vigilancias" OWNER TO "postgres";


ALTER TABLE ONLY "public"."activo_fijo_estados"
    ADD CONSTRAINT "activo_fijo_estados_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."activo_fijo_marcas"
    ADD CONSTRAINT "activo_fijo_marcas_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."activo_fijo_tipos"
    ADD CONSTRAINT "activo_fijo_tipos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."activos_fijos_historial"
    ADD CONSTRAINT "activos_fijos_historial_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."activos_fijos"
    ADD CONSTRAINT "activos_fijos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."annual_parameters"
    ADD CONSTRAINT "annual_parameters_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."annual_parameters"
    ADD CONSTRAINT "annual_parameters_tenant_id_year_key" UNIQUE ("tenant_id", "year");



ALTER TABLE ONLY "public"."audit_log"
    ADD CONSTRAINT "audit_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."certificate_templates"
    ADD CONSTRAINT "certificate_templates_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."committee_meetings"
    ADD CONSTRAINT "committee_meetings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."committee_members"
    ADD CONSTRAINT "committee_members_committee_id_employee_id_key" UNIQUE ("committee_id", "employee_id");



ALTER TABLE ONLY "public"."committee_members"
    ADD CONSTRAINT "committee_members_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."committee_roles"
    ADD CONSTRAINT "committee_roles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."committees"
    ADD CONSTRAINT "committees_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."communication_reads"
    ADD CONSTRAINT "communication_reads_communication_id_user_id_key" UNIQUE ("communication_id", "user_id");



ALTER TABLE ONLY "public"."communication_reads"
    ADD CONSTRAINT "communication_reads_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."communications"
    ADD CONSTRAINT "communications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."course_providers"
    ADD CONSTRAINT "course_providers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."course_types"
    ADD CONSTRAINT "course_types_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."courses"
    ADD CONSTRAINT "courses_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."departments"
    ADD CONSTRAINT "departments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."departments"
    ADD CONSTRAINT "departments_tenant_id_name_key" UNIQUE ("tenant_id", "name");



ALTER TABLE ONLY "public"."distribution_list_members"
    ADD CONSTRAINT "distribution_list_members_list_id_employee_id_key" UNIQUE ("list_id", "employee_id");



ALTER TABLE ONLY "public"."distribution_list_members"
    ADD CONSTRAINT "distribution_list_members_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."distribution_lists"
    ADD CONSTRAINT "distribution_lists_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."document_types"
    ADD CONSTRAINT "document_types_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dotacion"
    ADD CONSTRAINT "dotacion_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dotacion_types"
    ADD CONSTRAINT "dotacion_types_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."employee_activity_log"
    ADD CONSTRAINT "employee_activity_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."employee_contracts"
    ADD CONSTRAINT "employee_contracts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."employee_photos"
    ADD CONSTRAINT "employee_photos_employee_tenant_platform_key" UNIQUE ("employee_id", "tenant_id", "platform_id");



ALTER TABLE ONLY "public"."employee_photos"
    ADD CONSTRAINT "employee_photos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."employee_portal_accounts"
    ADD CONSTRAINT "employee_portal_accounts_employee_id_key" UNIQUE ("employee_id");



ALTER TABLE ONLY "public"."employee_portal_accounts"
    ADD CONSTRAINT "employee_portal_accounts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."employee_portal_accounts"
    ADD CONSTRAINT "employee_portal_accounts_synthetic_email_key" UNIQUE ("synthetic_email");



ALTER TABLE ONLY "public"."employees"
    ADD CONSTRAINT "employees_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."employees"
    ADD CONSTRAINT "employees_tenant_id_document_number_key" UNIQUE ("tenant_id", "document_number");



ALTER TABLE ONLY "public"."evaluation_responses"
    ADD CONSTRAINT "evaluation_responses_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."evaluation_template_criteria"
    ADD CONSTRAINT "evaluation_template_criteria_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."evaluation_template_sections"
    ADD CONSTRAINT "evaluation_template_sections_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."evaluation_templates"
    ADD CONSTRAINT "evaluation_templates_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."evaluation_types"
    ADD CONSTRAINT "evaluation_types_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."evaluations"
    ADD CONSTRAINT "evaluations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."event_participants"
    ADD CONSTRAINT "event_participants_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."event_types"
    ADD CONSTRAINT "event_types_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."events"
    ADD CONSTRAINT "events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."evidences"
    ADD CONSTRAINT "evidences_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."exam_types"
    ADD CONSTRAINT "exam_types_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."exams"
    ADD CONSTRAINT "exams_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."incapacidad_types"
    ADD CONSTRAINT "incapacidad_types_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."incapacidades"
    ADD CONSTRAINT "incapacidades_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."modules"
    ADD CONSTRAINT "modules_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."modules"
    ADD CONSTRAINT "modules_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."notification_preferences"
    ADD CONSTRAINT "notification_preferences_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."notification_preferences"
    ADD CONSTRAINT "notification_preferences_user_id_tenant_id_key" UNIQUE ("user_id", "tenant_id");



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."payroll_items"
    ADD CONSTRAINT "payroll_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."payroll_periods"
    ADD CONSTRAINT "payroll_periods_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."payroll_records"
    ADD CONSTRAINT "payroll_records_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pending_summary_notifications"
    ADD CONSTRAINT "pending_summary_notifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."permissions"
    ADD CONSTRAINT "permissions_module_id_action_key" UNIQUE ("module_id", "action");



ALTER TABLE ONLY "public"."permissions"
    ADD CONSTRAINT "permissions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."positions"
    ADD CONSTRAINT "positions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."positions"
    ADD CONSTRAINT "positions_tenant_id_name_key" UNIQUE ("tenant_id", "name");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_user_id_key" UNIQUE ("user_id");



ALTER TABLE ONLY "public"."regulation_acknowledgments"
    ADD CONSTRAINT "regulation_acknowledgments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."regulation_acknowledgments"
    ADD CONSTRAINT "regulation_acknowledgments_regulation_id_employee_id_key" UNIQUE ("regulation_id", "employee_id");



ALTER TABLE ONLY "public"."regulations"
    ADD CONSTRAINT "regulations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."role_notification_preferences"
    ADD CONSTRAINT "role_notification_preferences_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."role_notification_preferences"
    ADD CONSTRAINT "role_notification_preferences_role_id_tenant_id_key" UNIQUE ("role_id", "tenant_id");



ALTER TABLE ONLY "public"."role_permissions"
    ADD CONSTRAINT "role_permissions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."role_permissions"
    ADD CONSTRAINT "role_permissions_role_id_permission_id_key" UNIQUE ("role_id", "permission_id");



ALTER TABLE ONLY "public"."roles"
    ADD CONSTRAINT "roles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."roles"
    ADD CONSTRAINT "roles_tenant_id_name_key" UNIQUE ("tenant_id", "name");



ALTER TABLE ONLY "public"."signatures"
    ADD CONSTRAINT "signatures_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tenant_settings"
    ADD CONSTRAINT "tenant_settings_pkey" PRIMARY KEY ("tenant_id", "platform_id", "setting_key");



ALTER TABLE ONLY "public"."tenant_social_networks"
    ADD CONSTRAINT "tenant_social_networks_pkey" PRIMARY KEY ("id", "tenant_id", "platform_id");



ALTER TABLE ONLY "public"."tenant_social_networks"
    ADD CONSTRAINT "tenant_social_networks_platform_tenant_network_key" UNIQUE ("platform_id", "tenant_id", "network");



ALTER TABLE ONLY "public"."tenants"
    ADD CONSTRAINT "tenants_id_key" UNIQUE ("id");



ALTER TABLE ONLY "public"."tenants"
    ADD CONSTRAINT "tenants_pkey" PRIMARY KEY ("id", "platform_id");



ALTER TABLE ONLY "public"."tenants"
    ADD CONSTRAINT "unique_platform_country_slug" UNIQUE ("platform_id", "country_id", "slug");



ALTER TABLE ONLY "public"."user_permissions"
    ADD CONSTRAINT "user_permissions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_permissions"
    ADD CONSTRAINT "user_permissions_user_id_permission_id_key" UNIQUE ("user_id", "permission_id");



ALTER TABLE ONLY "public"."user_roles"
    ADD CONSTRAINT "user_roles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_roles"
    ADD CONSTRAINT "user_roles_user_id_role_id_key" UNIQUE ("user_id", "role_id");



ALTER TABLE ONLY "public"."vigilancia_types"
    ADD CONSTRAINT "vigilancia_types_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."vigilancias"
    ADD CONSTRAINT "vigilancias_pkey" PRIMARY KEY ("id");



CREATE UNIQUE INDEX "document_types_standard_code_idx" ON "public"."document_types" USING "btree" ("code") WHERE ("is_standard" = true);



CREATE UNIQUE INDEX "document_types_tenant_code_idx" ON "public"."document_types" USING "btree" ("tenant_id", "code") WHERE ("tenant_id" IS NOT NULL);



CREATE INDEX "idx_activity_log_employee" ON "public"."employee_activity_log" USING "btree" ("employee_id", "created_at" DESC);



CREATE INDEX "idx_activity_log_tenant" ON "public"."employee_activity_log" USING "btree" ("tenant_id");



CREATE INDEX "idx_activos_fijos_empleado" ON "public"."activos_fijos" USING "btree" ("empleado_asignado_id");



CREATE INDEX "idx_activos_fijos_estado_id" ON "public"."activos_fijos" USING "btree" ("estado_id");



CREATE INDEX "idx_activos_fijos_tenant" ON "public"."activos_fijos" USING "btree" ("tenant_id");



CREATE INDEX "idx_activos_fijos_tipo_id" ON "public"."activos_fijos" USING "btree" ("tipo_id");



CREATE INDEX "idx_employee_photos_employee_id" ON "public"."employee_photos" USING "btree" ("employee_id");



CREATE INDEX "idx_employee_photos_tenant_id" ON "public"."employee_photos" USING "btree" ("tenant_id");



CREATE INDEX "idx_epa_tenant" ON "public"."employee_portal_accounts" USING "btree" ("tenant_id");



CREATE INDEX "idx_epa_user" ON "public"."employee_portal_accounts" USING "btree" ("user_id");



CREATE INDEX "idx_exams_exam_date" ON "public"."exams" USING "btree" ("exam_date");



CREATE INDEX "idx_exams_scheduled_date" ON "public"."exams" USING "btree" ("scheduled_date");



CREATE INDEX "idx_exams_status" ON "public"."exams" USING "btree" ("status");



CREATE INDEX "idx_historial_activo" ON "public"."activos_fijos_historial" USING "btree" ("activo_fijo_id");



CREATE INDEX "idx_historial_empleado" ON "public"."activos_fijos_historial" USING "btree" ("empleado_id");



CREATE INDEX "idx_incapacidades_employee" ON "public"."incapacidades" USING "btree" ("employee_id");



CREATE INDEX "idx_incapacidades_estado" ON "public"."incapacidades" USING "btree" ("estado");



CREATE INDEX "idx_incapacidades_tenant" ON "public"."incapacidades" USING "btree" ("tenant_id");



CREATE INDEX "idx_notifications_employee" ON "public"."notifications" USING "btree" ("employee_id");



CREATE INDEX "idx_tenant_settings_data" ON "public"."tenant_settings" USING "gin" ("settings_data");



CREATE INDEX "idx_tenants_country_id" ON "public"."tenants" USING "btree" ("country_id");



CREATE UNIQUE INDEX "unique_owner_per_platform" ON "public"."tenants" USING "btree" ("platform_id") WHERE ("is_system_owner" = true);



CREATE OR REPLACE TRIGGER "employees_revoke_portal_on_retire" AFTER UPDATE ON "public"."employees" FOR EACH ROW EXECUTE FUNCTION "public"."revoke_portal_on_retire"();



CREATE OR REPLACE TRIGGER "sync_super_admin_trigger" AFTER INSERT OR DELETE ON "public"."user_roles" FOR EACH ROW EXECUTE FUNCTION "public"."sync_super_admin_on_role_change"();



CREATE OR REPLACE TRIGGER "trg_activo_fijo_estados_updated" BEFORE UPDATE ON "public"."activo_fijo_estados" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "trg_activo_fijo_marcas_updated" BEFORE UPDATE ON "public"."activo_fijo_marcas" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "trg_activo_fijo_tipos_updated" BEFORE UPDATE ON "public"."activo_fijo_tipos" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "trg_activos_fijos_updated" BEFORE UPDATE ON "public"."activos_fijos" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "trg_incapacidad_types_updated" BEFORE UPDATE ON "public"."incapacidad_types" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "trg_incapacidades_updated" BEFORE UPDATE ON "public"."incapacidades" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "trigger_tenants_updated_at" BEFORE UPDATE ON "public"."tenants" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_committee_meetings_updated_at" BEFORE UPDATE ON "public"."committee_meetings" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_committee_roles_updated_at" BEFORE UPDATE ON "public"."committee_roles" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_committees_updated_at" BEFORE UPDATE ON "public"."committees" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_communications_updated_at" BEFORE UPDATE ON "public"."communications" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_course_providers_updated_at" BEFORE UPDATE ON "public"."course_providers" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_course_types_updated_at" BEFORE UPDATE ON "public"."course_types" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_courses_updated_at" BEFORE UPDATE ON "public"."courses" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_dotacion_types_updated_at" BEFORE UPDATE ON "public"."dotacion_types" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_dotacion_updated_at" BEFORE UPDATE ON "public"."dotacion" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_employees_updated_at" BEFORE UPDATE ON "public"."employees" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_epa_updated_at" BEFORE UPDATE ON "public"."employee_portal_accounts" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_evaluation_templates_updated_at" BEFORE UPDATE ON "public"."evaluation_templates" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_evaluation_types_updated_at" BEFORE UPDATE ON "public"."evaluation_types" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_evaluations_updated_at" BEFORE UPDATE ON "public"."evaluations" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_events_updated_at" BEFORE UPDATE ON "public"."events" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_evidences_updated_at" BEFORE UPDATE ON "public"."evidences" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_exam_types_updated_at" BEFORE UPDATE ON "public"."exam_types" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_exams_updated_at" BEFORE UPDATE ON "public"."exams" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_notification_preferences_updated_at" BEFORE UPDATE ON "public"."notification_preferences" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_profiles_updated_at" BEFORE UPDATE ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_role_notification_preferences_updated_at" BEFORE UPDATE ON "public"."role_notification_preferences" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_roles_updated_at" BEFORE UPDATE ON "public"."roles" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_signatures_updated_at" BEFORE UPDATE ON "public"."signatures" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_tenants_updated_at" BEFORE UPDATE ON "public"."tenants" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_vigilancia_types_updated_at" BEFORE UPDATE ON "public"."vigilancia_types" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_vigilancias_updated_at" BEFORE UPDATE ON "public"."vigilancias" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



ALTER TABLE ONLY "public"."activo_fijo_estados"
    ADD CONSTRAINT "activo_fijo_estados_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."activo_fijo_marcas"
    ADD CONSTRAINT "activo_fijo_marcas_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."activo_fijo_tipos"
    ADD CONSTRAINT "activo_fijo_tipos_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."activos_fijos"
    ADD CONSTRAINT "activos_fijos_empleado_asignado_id_fkey" FOREIGN KEY ("empleado_asignado_id") REFERENCES "public"."employees"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."activos_fijos"
    ADD CONSTRAINT "activos_fijos_estado_id_fkey" FOREIGN KEY ("estado_id") REFERENCES "public"."activo_fijo_estados"("id");



ALTER TABLE ONLY "public"."activos_fijos_historial"
    ADD CONSTRAINT "activos_fijos_historial_activo_fijo_id_fkey" FOREIGN KEY ("activo_fijo_id") REFERENCES "public"."activos_fijos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."activos_fijos_historial"
    ADD CONSTRAINT "activos_fijos_historial_empleado_id_fkey" FOREIGN KEY ("empleado_id") REFERENCES "public"."employees"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."activos_fijos"
    ADD CONSTRAINT "activos_fijos_marca_id_fkey" FOREIGN KEY ("marca_id") REFERENCES "public"."activo_fijo_marcas"("id");



ALTER TABLE ONLY "public"."activos_fijos"
    ADD CONSTRAINT "activos_fijos_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."activos_fijos"
    ADD CONSTRAINT "activos_fijos_tipo_id_fkey" FOREIGN KEY ("tipo_id") REFERENCES "public"."activo_fijo_tipos"("id");



ALTER TABLE ONLY "public"."audit_log"
    ADD CONSTRAINT "audit_log_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."committee_meetings"
    ADD CONSTRAINT "committee_meetings_committee_id_fkey" FOREIGN KEY ("committee_id") REFERENCES "public"."committees"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."committee_meetings"
    ADD CONSTRAINT "committee_meetings_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."committee_members"
    ADD CONSTRAINT "committee_members_committee_id_fkey" FOREIGN KEY ("committee_id") REFERENCES "public"."committees"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."committee_members"
    ADD CONSTRAINT "committee_members_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."communication_reads"
    ADD CONSTRAINT "communication_reads_communication_id_fkey" FOREIGN KEY ("communication_id") REFERENCES "public"."communications"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."communication_reads"
    ADD CONSTRAINT "communication_reads_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."communications"
    ADD CONSTRAINT "communications_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."courses"
    ADD CONSTRAINT "courses_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."courses"
    ADD CONSTRAINT "courses_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."distribution_list_members"
    ADD CONSTRAINT "distribution_list_members_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."distribution_list_members"
    ADD CONSTRAINT "distribution_list_members_list_id_fkey" FOREIGN KEY ("list_id") REFERENCES "public"."distribution_lists"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."distribution_lists"
    ADD CONSTRAINT "distribution_lists_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."dotacion"
    ADD CONSTRAINT "dotacion_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."dotacion"
    ADD CONSTRAINT "dotacion_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."employee_activity_log"
    ADD CONSTRAINT "employee_activity_log_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."employee_activity_log"
    ADD CONSTRAINT "employee_activity_log_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."employee_contracts"
    ADD CONSTRAINT "employee_contracts_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."employee_portal_accounts"
    ADD CONSTRAINT "employee_portal_accounts_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."employees"
    ADD CONSTRAINT "employees_supervisor_id_fkey" FOREIGN KEY ("supervisor_id") REFERENCES "public"."employees"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."evaluation_responses"
    ADD CONSTRAINT "evaluation_responses_criterion_id_fkey" FOREIGN KEY ("criterion_id") REFERENCES "public"."evaluation_template_criteria"("id");



ALTER TABLE ONLY "public"."evaluation_responses"
    ADD CONSTRAINT "evaluation_responses_evaluation_id_fkey" FOREIGN KEY ("evaluation_id") REFERENCES "public"."evaluations"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."evaluation_template_criteria"
    ADD CONSTRAINT "evaluation_template_criteria_section_id_fkey" FOREIGN KEY ("section_id") REFERENCES "public"."evaluation_template_sections"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."evaluation_template_sections"
    ADD CONSTRAINT "evaluation_template_sections_template_id_fkey" FOREIGN KEY ("template_id") REFERENCES "public"."evaluation_templates"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."evaluations"
    ADD CONSTRAINT "evaluations_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id");



ALTER TABLE ONLY "public"."evaluations"
    ADD CONSTRAINT "evaluations_evaluator_id_fkey" FOREIGN KEY ("evaluator_id") REFERENCES "public"."employees"("id");



ALTER TABLE ONLY "public"."evaluations"
    ADD CONSTRAINT "evaluations_template_id_fkey" FOREIGN KEY ("template_id") REFERENCES "public"."evaluation_templates"("id");



ALTER TABLE ONLY "public"."event_participants"
    ADD CONSTRAINT "event_participants_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id");



ALTER TABLE ONLY "public"."event_participants"
    ADD CONSTRAINT "event_participants_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."evidences"
    ADD CONSTRAINT "evidences_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id");



ALTER TABLE ONLY "public"."evidences"
    ADD CONSTRAINT "evidences_uploaded_by_employee_id_fkey" FOREIGN KEY ("uploaded_by_employee_id") REFERENCES "public"."employees"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."exams"
    ADD CONSTRAINT "exams_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."exams"
    ADD CONSTRAINT "exams_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."employee_photos"
    ADD CONSTRAINT "fk_employee_photos_employee" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."employee_photos"
    ADD CONSTRAINT "fk_employee_photos_tenant" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."incapacidad_types"
    ADD CONSTRAINT "incapacidad_types_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."incapacidades"
    ADD CONSTRAINT "incapacidades_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."incapacidades"
    ADD CONSTRAINT "incapacidades_prorroga_de_fkey" FOREIGN KEY ("prorroga_de") REFERENCES "public"."incapacidades"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."incapacidades"
    ADD CONSTRAINT "incapacidades_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."payroll_items"
    ADD CONSTRAINT "payroll_items_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."payroll_items"
    ADD CONSTRAINT "payroll_items_period_id_fkey" FOREIGN KEY ("period_id") REFERENCES "public"."payroll_periods"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."payroll_records"
    ADD CONSTRAINT "payroll_records_contract_id_fkey" FOREIGN KEY ("contract_id") REFERENCES "public"."employee_contracts"("id");



ALTER TABLE ONLY "public"."payroll_records"
    ADD CONSTRAINT "payroll_records_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."payroll_records"
    ADD CONSTRAINT "payroll_records_period_id_fkey" FOREIGN KEY ("period_id") REFERENCES "public"."payroll_periods"("id");



ALTER TABLE ONLY "public"."permissions"
    ADD CONSTRAINT "permissions_module_id_fkey" FOREIGN KEY ("module_id") REFERENCES "public"."modules"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."regulation_acknowledgments"
    ADD CONSTRAINT "regulation_acknowledgments_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."regulation_acknowledgments"
    ADD CONSTRAINT "regulation_acknowledgments_regulation_id_fkey" FOREIGN KEY ("regulation_id") REFERENCES "public"."regulations"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."role_notification_preferences"
    ADD CONSTRAINT "role_notification_preferences_role_id_fkey" FOREIGN KEY ("role_id") REFERENCES "public"."roles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."role_permissions"
    ADD CONSTRAINT "role_permissions_permission_id_fkey" FOREIGN KEY ("permission_id") REFERENCES "public"."permissions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."role_permissions"
    ADD CONSTRAINT "role_permissions_role_id_fkey" FOREIGN KEY ("role_id") REFERENCES "public"."roles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."signatures"
    ADD CONSTRAINT "signatures_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id");



ALTER TABLE ONLY "public"."tenant_settings"
    ADD CONSTRAINT "tenant_settings_tenant_id_fkey" FOREIGN KEY ("platform_id", "tenant_id") REFERENCES "public"."tenants"("platform_id", "id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tenant_social_networks"
    ADD CONSTRAINT "tenant_social_networks_tenant_id_fkey" FOREIGN KEY ("tenant_id", "platform_id") REFERENCES "public"."tenants"("id", "platform_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_permissions"
    ADD CONSTRAINT "user_permissions_permission_id_fkey" FOREIGN KEY ("permission_id") REFERENCES "public"."permissions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_permissions"
    ADD CONSTRAINT "user_permissions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_roles"
    ADD CONSTRAINT "user_roles_role_id_fkey" FOREIGN KEY ("role_id") REFERENCES "public"."roles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_roles"
    ADD CONSTRAINT "user_roles_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."vigilancias"
    ADD CONSTRAINT "vigilancias_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."vigilancias"
    ADD CONSTRAINT "vigilancias_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id") ON DELETE CASCADE;



CREATE POLICY "Authenticated users can view modules" ON "public"."modules" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can view permissions" ON "public"."permissions" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Create annual_parameters" ON "public"."annual_parameters" FOR INSERT WITH CHECK (("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())));



CREATE POLICY "Create certificate_templates" ON "public"."certificate_templates" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'nomina'::"text", 'crear'::"public"."permission_action"))));



CREATE POLICY "Create committees" ON "public"."committees" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'comites'::"text", 'crear'::"public"."permission_action"))));



CREATE POLICY "Create communications" ON "public"."communications" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'comunicaciones'::"text", 'crear'::"public"."permission_action"))));



CREATE POLICY "Create courses" ON "public"."courses" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'cursos'::"text", 'crear'::"public"."permission_action"))));



CREATE POLICY "Create dotacion" ON "public"."dotacion" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'dotacion'::"text", 'crear'::"public"."permission_action"))));



CREATE POLICY "Create employee_contracts" ON "public"."employee_contracts" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'nomina'::"text", 'crear'::"public"."permission_action"))));



CREATE POLICY "Create evaluation_templates" ON "public"."evaluation_templates" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'evaluaciones'::"text", 'crear'::"public"."permission_action"))));



CREATE POLICY "Create evaluations" ON "public"."evaluations" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'evaluaciones'::"text", 'crear'::"public"."permission_action"))));



CREATE POLICY "Create events" ON "public"."events" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'eventos'::"text", 'crear'::"public"."permission_action"))));



CREATE POLICY "Create evidences" ON "public"."evidences" FOR INSERT TO "authenticated" WITH CHECK ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), "module", 'crear'::"public"."permission_action"))));



CREATE POLICY "Create exams" ON "public"."exams" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'examenes'::"text", 'crear'::"public"."permission_action"))));



CREATE POLICY "Create payroll_items" ON "public"."payroll_items" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'nomina'::"text", 'crear'::"public"."permission_action"))));



CREATE POLICY "Create payroll_periods" ON "public"."payroll_periods" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'nomina'::"text", 'crear'::"public"."permission_action"))));



CREATE POLICY "Create payroll_records" ON "public"."payroll_records" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'nomina'::"text", 'crear'::"public"."permission_action"))));



CREATE POLICY "Create regulation_acknowledgments" ON "public"."regulation_acknowledgments" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'reglamento'::"text", 'crear'::"public"."permission_action"))));



CREATE POLICY "Create regulations" ON "public"."regulations" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'reglamento'::"text", 'crear'::"public"."permission_action"))));



CREATE POLICY "Create signatures" ON "public"."signatures" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'firmas'::"text", 'firmar'::"public"."permission_action"))));



CREATE POLICY "Create vigilancias" ON "public"."vigilancias" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'vigilancias'::"text", 'crear'::"public"."permission_action"))));



CREATE POLICY "Delete annual_parameters" ON "public"."annual_parameters" FOR DELETE USING (("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())));



CREATE POLICY "Delete certificate_templates" ON "public"."certificate_templates" FOR DELETE USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'nomina'::"text", 'eliminar'::"public"."permission_action"))));



CREATE POLICY "Delete committees" ON "public"."committees" FOR DELETE USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'comites'::"text", 'eliminar'::"public"."permission_action"))));



CREATE POLICY "Delete communications" ON "public"."communications" FOR DELETE USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'comunicaciones'::"text", 'eliminar'::"public"."permission_action"))));



CREATE POLICY "Delete courses" ON "public"."courses" FOR DELETE USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'cursos'::"text", 'eliminar'::"public"."permission_action"))));



CREATE POLICY "Delete dotacion" ON "public"."dotacion" FOR DELETE USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'dotacion'::"text", 'eliminar'::"public"."permission_action"))));



CREATE POLICY "Delete employee_contracts" ON "public"."employee_contracts" FOR DELETE USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'nomina'::"text", 'eliminar'::"public"."permission_action"))));



CREATE POLICY "Delete evaluation_templates" ON "public"."evaluation_templates" FOR DELETE USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'evaluaciones'::"text", 'eliminar'::"public"."permission_action"))));



CREATE POLICY "Delete evaluations" ON "public"."evaluations" FOR DELETE USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'evaluaciones'::"text", 'eliminar'::"public"."permission_action"))));



CREATE POLICY "Delete events" ON "public"."events" FOR DELETE USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'eventos'::"text", 'eliminar'::"public"."permission_action"))));



CREATE POLICY "Delete evidences" ON "public"."evidences" FOR DELETE TO "authenticated" USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), "module", 'eliminar'::"public"."permission_action"))));



CREATE POLICY "Delete exams" ON "public"."exams" FOR DELETE USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'examenes'::"text", 'eliminar'::"public"."permission_action"))));



CREATE POLICY "Delete payroll_items" ON "public"."payroll_items" FOR DELETE USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'nomina'::"text", 'eliminar'::"public"."permission_action"))));



CREATE POLICY "Delete payroll_periods" ON "public"."payroll_periods" FOR DELETE USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'nomina'::"text", 'eliminar'::"public"."permission_action"))));



CREATE POLICY "Delete payroll_records" ON "public"."payroll_records" FOR DELETE USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'nomina'::"text", 'eliminar'::"public"."permission_action"))));



CREATE POLICY "Delete regulations" ON "public"."regulations" FOR DELETE USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'reglamento'::"text", 'eliminar'::"public"."permission_action"))));



CREATE POLICY "Delete signatures" ON "public"."signatures" FOR DELETE USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'firmas'::"text", 'eliminar'::"public"."permission_action"))));



CREATE POLICY "Delete vigilancias" ON "public"."vigilancias" FOR DELETE USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'vigilancias'::"text", 'eliminar'::"public"."permission_action"))));



CREATE POLICY "Employee portal: confirm own attendance" ON "public"."event_participants" FOR UPDATE TO "authenticated" USING (("employee_id" = "public"."get_current_employee_id"())) WITH CHECK (("employee_id" = "public"."get_current_employee_id"()));



CREATE POLICY "Employee portal: create own ack" ON "public"."regulation_acknowledgments" FOR INSERT TO "authenticated" WITH CHECK (("employee_id" = "public"."get_current_employee_id"()));



CREATE POLICY "Employee portal: create own evidences" ON "public"."evidences" FOR INSERT TO "authenticated" WITH CHECK (("employee_id" = "public"."get_current_employee_id"()));



CREATE POLICY "Employee portal: create own signatures" ON "public"."signatures" FOR INSERT TO "authenticated" WITH CHECK (("employee_id" = "public"."get_current_employee_id"()));



CREATE POLICY "Employee portal: manage own evaluation responses" ON "public"."evaluation_responses" TO "authenticated" USING (("evaluation_id" IN ( SELECT "evaluations"."id"
   FROM "public"."evaluations"
  WHERE (("evaluations"."employee_id" = "public"."get_current_employee_id"()) OR ("evaluations"."evaluator_id" = "public"."get_current_employee_id"()))))) WITH CHECK (("evaluation_id" IN ( SELECT "evaluations"."id"
   FROM "public"."evaluations"
  WHERE (("evaluations"."employee_id" = "public"."get_current_employee_id"()) OR ("evaluations"."evaluator_id" = "public"."get_current_employee_id"())))));



CREATE POLICY "Employee portal: read assigned events" ON "public"."events" FOR SELECT TO "authenticated" USING (("id" IN ( SELECT "event_participants"."event_id"
   FROM "public"."event_participants"
  WHERE ("event_participants"."employee_id" = "public"."get_current_employee_id"()))));



CREATE POLICY "Employee portal: read own ack" ON "public"."regulation_acknowledgments" FOR SELECT TO "authenticated" USING (("employee_id" = "public"."get_current_employee_id"()));



CREATE POLICY "Employee portal: read own courses" ON "public"."courses" FOR SELECT TO "authenticated" USING (("employee_id" = "public"."get_current_employee_id"()));



CREATE POLICY "Employee portal: read own dotacion" ON "public"."dotacion" FOR SELECT TO "authenticated" USING (("employee_id" = "public"."get_current_employee_id"()));



CREATE POLICY "Employee portal: read own employee row" ON "public"."employees" FOR SELECT TO "authenticated" USING (("id" = "public"."get_current_employee_id"()));



CREATE POLICY "Employee portal: read own evaluations" ON "public"."evaluations" FOR SELECT TO "authenticated" USING ((("employee_id" = "public"."get_current_employee_id"()) OR ("evaluator_id" = "public"."get_current_employee_id"())));



CREATE POLICY "Employee portal: read own event participation" ON "public"."event_participants" FOR SELECT TO "authenticated" USING (("employee_id" = "public"."get_current_employee_id"()));



CREATE POLICY "Employee portal: read own evidences" ON "public"."evidences" FOR SELECT TO "authenticated" USING (("employee_id" = "public"."get_current_employee_id"()));



CREATE POLICY "Employee portal: read own exams" ON "public"."exams" FOR SELECT TO "authenticated" USING (("employee_id" = "public"."get_current_employee_id"()));



CREATE POLICY "Employee portal: read own payroll" ON "public"."payroll_records" FOR SELECT TO "authenticated" USING (("employee_id" = "public"."get_current_employee_id"()));



CREATE POLICY "Employee portal: read own payroll items" ON "public"."payroll_items" FOR SELECT TO "authenticated" USING (("employee_id" = "public"."get_current_employee_id"()));



CREATE POLICY "Employee portal: read own signatures" ON "public"."signatures" FOR SELECT TO "authenticated" USING (("employee_id" = "public"."get_current_employee_id"()));



CREATE POLICY "Employee portal: read own vigilancias" ON "public"."vigilancias" FOR SELECT TO "authenticated" USING (("employee_id" = "public"."get_current_employee_id"()));



CREATE POLICY "Employee portal: read regulations of own tenant" ON "public"."regulations" FOR SELECT TO "authenticated" USING (("tenant_id" = ( SELECT "employees"."tenant_id"
   FROM "public"."employees"
  WHERE ("employees"."id" = "public"."get_current_employee_id"()))));



CREATE POLICY "Employee portal: read template criteria" ON "public"."evaluation_template_criteria" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM (("public"."evaluation_template_sections" "s"
     JOIN "public"."evaluation_templates" "t" ON (("t"."id" = "s"."template_id")))
     JOIN "public"."employee_portal_accounts" "epa" ON (("epa"."tenant_id" = "t"."tenant_id")))
  WHERE (("s"."id" = "evaluation_template_criteria"."section_id") AND ("epa"."user_id" = "auth"."uid"()) AND ("epa"."status" = 'active'::"text")))));



CREATE POLICY "Employee portal: read template sections" ON "public"."evaluation_template_sections" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM ("public"."evaluation_templates" "t"
     JOIN "public"."employee_portal_accounts" "epa" ON (("epa"."tenant_id" = "t"."tenant_id")))
  WHERE (("t"."id" = "evaluation_template_sections"."template_id") AND ("epa"."user_id" = "auth"."uid"()) AND ("epa"."status" = 'active'::"text")))));



CREATE POLICY "Employee portal: read tenant certificate templates" ON "public"."certificate_templates" FOR SELECT TO "authenticated" USING (("tenant_id" = ( SELECT "employees"."tenant_id"
   FROM "public"."employees"
  WHERE ("employees"."id" = "public"."get_current_employee_id"()))));



CREATE POLICY "Employee portal: read tenant evaluation templates" ON "public"."evaluation_templates" FOR SELECT USING (("tenant_id" = ( SELECT "employee_portal_accounts"."tenant_id"
   FROM "public"."employee_portal_accounts"
  WHERE (("employee_portal_accounts"."user_id" = "auth"."uid"()) AND ("employee_portal_accounts"."status" = 'active'::"text"))
 LIMIT 1)));



CREATE POLICY "Employee portal: respond evaluations" ON "public"."evaluations" FOR UPDATE TO "authenticated" USING ((("employee_id" = "public"."get_current_employee_id"()) OR ("evaluator_id" = "public"."get_current_employee_id"()))) WITH CHECK ((("employee_id" = "public"."get_current_employee_id"()) OR ("evaluator_id" = "public"."get_current_employee_id"())));



CREATE POLICY "Employee portal: sign own dotacion" ON "public"."dotacion" FOR UPDATE TO "authenticated" USING (("employee_id" = "public"."get_current_employee_id"())) WITH CHECK (("employee_id" = "public"."get_current_employee_id"()));



CREATE POLICY "Employee portal: update own ack" ON "public"."regulation_acknowledgments" FOR UPDATE TO "authenticated" USING (("employee_id" = "public"."get_current_employee_id"())) WITH CHECK (("employee_id" = "public"."get_current_employee_id"()));



CREATE POLICY "Employee portal: update own employee row" ON "public"."employees" FOR UPDATE TO "authenticated" USING (("id" = "public"."get_current_employee_id"())) WITH CHECK (("id" = "public"."get_current_employee_id"()));



CREATE POLICY "Employee portal: update own profile" ON "public"."employees" FOR UPDATE USING (("id" = "public"."get_current_employee_id"())) WITH CHECK (("id" = "public"."get_current_employee_id"()));



CREATE POLICY "Employee sees own portal account" ON "public"."employee_portal_accounts" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "Everyone can view standard committee roles" ON "public"."committee_roles" FOR SELECT USING (("is_standard" = true));



CREATE POLICY "Everyone can view standard course providers" ON "public"."course_providers" FOR SELECT USING (("is_standard" = true));



CREATE POLICY "Everyone can view standard course types" ON "public"."course_types" FOR SELECT USING (("is_standard" = true));



CREATE POLICY "Everyone can view standard dotacion types" ON "public"."dotacion_types" FOR SELECT USING (("is_standard" = true));



CREATE POLICY "Everyone can view standard evaluation types" ON "public"."evaluation_types" FOR SELECT USING (("is_standard" = true));



CREATE POLICY "Everyone can view standard event types" ON "public"."event_types" FOR SELECT USING (("is_standard" = true));



CREATE POLICY "Everyone can view standard exam types" ON "public"."exam_types" FOR SELECT USING (("is_standard" = true));



CREATE POLICY "Everyone can view standard vigilancia types" ON "public"."vigilancia_types" FOR SELECT USING (("is_standard" = true));



CREATE POLICY "Los usuarios pueden actualizar listas de su tenant" ON "public"."distribution_lists" FOR UPDATE USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) OR "public"."is_super_admin"("auth"."uid"())));



CREATE POLICY "Los usuarios pueden actualizar miembros de listas de su tenant" ON "public"."distribution_list_members" FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM "public"."distribution_lists" "dl"
  WHERE (("dl"."id" = "distribution_list_members"."list_id") AND (("dl"."tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) OR "public"."is_super_admin"("auth"."uid"()))))));



CREATE POLICY "Los usuarios pueden eliminar listas de su tenant" ON "public"."distribution_lists" FOR DELETE USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) OR "public"."is_super_admin"("auth"."uid"())));



CREATE POLICY "Los usuarios pueden eliminar miembros de listas de su tenant" ON "public"."distribution_list_members" FOR DELETE USING ((EXISTS ( SELECT 1
   FROM "public"."distribution_lists" "dl"
  WHERE (("dl"."id" = "distribution_list_members"."list_id") AND (("dl"."tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) OR "public"."is_super_admin"("auth"."uid"()))))));



CREATE POLICY "Los usuarios pueden insertar listas de su tenant" ON "public"."distribution_lists" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) OR "public"."is_super_admin"("auth"."uid"())));



CREATE POLICY "Los usuarios pueden insertar miembros de listas de su tenant" ON "public"."distribution_list_members" FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."distribution_lists" "dl"
  WHERE (("dl"."id" = "distribution_list_members"."list_id") AND (("dl"."tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) OR "public"."is_super_admin"("auth"."uid"()))))));



CREATE POLICY "Los usuarios pueden ver listas de su tenant" ON "public"."distribution_lists" FOR SELECT USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) OR "public"."is_super_admin"("auth"."uid"())));



CREATE POLICY "Los usuarios pueden ver miembros de listas de su tenant" ON "public"."distribution_list_members" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."distribution_lists" "dl"
  WHERE (("dl"."id" = "distribution_list_members"."list_id") AND (("dl"."tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) OR "public"."is_super_admin"("auth"."uid"()))))));



CREATE POLICY "Manage own tenant activo fijo estados" ON "public"."activo_fijo_estados" TO "authenticated" USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("is_standard" = false))) WITH CHECK ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("is_standard" = false)));



CREATE POLICY "Manage own tenant activo fijo marcas" ON "public"."activo_fijo_marcas" TO "authenticated" USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("is_standard" = false))) WITH CHECK ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("is_standard" = false)));



CREATE POLICY "Manage own tenant activo fijo tipos" ON "public"."activo_fijo_tipos" TO "authenticated" USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("is_standard" = false))) WITH CHECK ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("is_standard" = false)));



CREATE POLICY "Manage own tenant incapacidad types" ON "public"."incapacidad_types" TO "authenticated" USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("is_standard" = false))) WITH CHECK ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("is_standard" = false)));



CREATE POLICY "Portal employee creates own incapacidad" ON "public"."incapacidades" FOR INSERT TO "authenticated" WITH CHECK ((("employee_id" = "public"."get_current_employee_id"()) AND ("origen" = 'portal_empleado'::"public"."incapacidad_origen") AND ("estado" = 'registrada'::"public"."incapacidad_estado")));



CREATE POLICY "Portal employee inserts own activity" ON "public"."employee_activity_log" FOR INSERT TO "authenticated" WITH CHECK (("employee_id" = "public"."get_current_employee_id"()));



CREATE POLICY "Portal employee inserts own evidences" ON "public"."evidences" FOR INSERT TO "authenticated" WITH CHECK ((("employee_id" = "public"."get_current_employee_id"()) AND ("uploaded_by_employee_id" = "public"."get_current_employee_id"()) AND ("tenant_id" = ( SELECT "employees"."tenant_id"
   FROM "public"."employees"
  WHERE ("employees"."id" = "public"."get_current_employee_id"())))));



CREATE POLICY "Portal employee updates own notifications" ON "public"."notifications" FOR UPDATE TO "authenticated" USING ((("employee_id" IS NOT NULL) AND ("employee_id" = "public"."get_current_employee_id"())));



CREATE POLICY "Portal employee views own activity" ON "public"."employee_activity_log" FOR SELECT TO "authenticated" USING (("employee_id" = "public"."get_current_employee_id"()));



CREATE POLICY "Portal employee views own evidences" ON "public"."evidences" FOR SELECT TO "authenticated" USING (("employee_id" = "public"."get_current_employee_id"()));



CREATE POLICY "Portal employee views own incapacidades" ON "public"."incapacidades" FOR SELECT TO "authenticated" USING (("employee_id" = "public"."get_current_employee_id"()));



CREATE POLICY "Portal employee views own notifications" ON "public"."notifications" FOR SELECT TO "authenticated" USING ((("employee_id" IS NOT NULL) AND ("employee_id" = "public"."get_current_employee_id"())));



CREATE POLICY "Portal employees can manage own photo" ON "public"."employee_photos" FOR INSERT WITH CHECK (("employee_id" = "public"."get_current_employee_id"()));



CREATE POLICY "Portal employees can read tenant_settings" ON "public"."tenant_settings" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."employee_portal_accounts"
  WHERE (("employee_portal_accounts"."user_id" = "auth"."uid"()) AND ("employee_portal_accounts"."tenant_id" = "tenant_settings"."tenant_id") AND ("employee_portal_accounts"."status" = 'active'::"text")))));



CREATE POLICY "Portal employees can update own account" ON "public"."employee_portal_accounts" FOR UPDATE TO "authenticated" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "Portal employees can view own photo" ON "public"."employee_photos" FOR SELECT USING (("employee_id" = "public"."get_current_employee_id"()));



CREATE POLICY "Super admins can manage all committee roles" ON "public"."committee_roles" USING ("public"."is_super_admin"("auth"."uid"()));



CREATE POLICY "Super admins can manage all course providers" ON "public"."course_providers" USING ("public"."is_super_admin"("auth"."uid"()));



CREATE POLICY "Super admins can manage all course types" ON "public"."course_types" USING ("public"."is_super_admin"("auth"."uid"()));



CREATE POLICY "Super admins can manage all dotacion types" ON "public"."dotacion_types" USING ("public"."is_super_admin"("auth"."uid"()));



CREATE POLICY "Super admins can manage all evaluation types" ON "public"."evaluation_types" USING ("public"."is_super_admin"("auth"."uid"()));



CREATE POLICY "Super admins can manage all event types" ON "public"."event_types" USING ("public"."is_super_admin"("auth"."uid"()));



CREATE POLICY "Super admins can manage all exam types" ON "public"."exam_types" USING ("public"."is_super_admin"("auth"."uid"()));



CREATE POLICY "Super admins can manage all profiles" ON "public"."profiles" USING ("public"."is_super_admin"("auth"."uid"()));



CREATE POLICY "Super admins can manage all role notification preferences" ON "public"."role_notification_preferences" USING ("public"."is_super_admin"("auth"."uid"()));



CREATE POLICY "Super admins can manage all role permissions" ON "public"."role_permissions" USING ("public"."is_super_admin"("auth"."uid"()));



CREATE POLICY "Super admins can manage all roles" ON "public"."roles" USING ("public"."is_super_admin"("auth"."uid"()));



CREATE POLICY "Super admins can manage all tenant_settings" ON "public"."tenant_settings" USING ("public"."is_super_admin"("auth"."uid"()));



CREATE POLICY "Super admins can manage all tenant_social_networks" ON "public"."tenant_social_networks" USING ("public"."is_super_admin"("auth"."uid"()));



CREATE POLICY "Super admins can manage all user permissions" ON "public"."user_permissions" USING ("public"."is_super_admin"("auth"."uid"()));



CREATE POLICY "Super admins can manage all user roles" ON "public"."user_roles" USING ("public"."is_super_admin"("auth"."uid"()));



CREATE POLICY "Super admins can manage all vigilancia types" ON "public"."vigilancia_types" USING ("public"."is_super_admin"("auth"."uid"()));



CREATE POLICY "Super admins can view all audit logs" ON "public"."audit_log" FOR SELECT USING ("public"."is_super_admin"("auth"."uid"()));



CREATE POLICY "System can manage pending notifications" ON "public"."pending_summary_notifications" USING ((("user_id" = "auth"."uid"()) OR "public"."is_super_admin"("auth"."uid"())));



CREATE POLICY "Tenant admins can delete role permissions" ON "public"."role_permissions" FOR DELETE USING ((EXISTS ( SELECT 1
   FROM "public"."roles" "r"
  WHERE (("r"."id" = "role_permissions"."role_id") AND ("r"."tenant_id" = "public"."get_user_tenant_id"("auth"."uid"()))))));



CREATE POLICY "Tenant admins can delete user roles" ON "public"."user_roles" FOR DELETE USING ((EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE (("p"."user_id" = "user_roles"."user_id") AND ("p"."tenant_id" = "public"."get_user_tenant_id"("auth"."uid"()))))));



CREATE POLICY "Tenant admins can insert role permissions" ON "public"."role_permissions" FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."roles" "r"
  WHERE (("r"."id" = "role_permissions"."role_id") AND ("r"."tenant_id" = "public"."get_user_tenant_id"("auth"."uid"()))))));



CREATE POLICY "Tenant admins can insert user roles" ON "public"."user_roles" FOR INSERT WITH CHECK (((EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE (("p"."user_id" = "user_roles"."user_id") AND ("p"."tenant_id" = "public"."get_user_tenant_id"("auth"."uid"()))))) AND (EXISTS ( SELECT 1
   FROM "public"."roles" "r"
  WHERE (("r"."id" = "user_roles"."role_id") AND ("r"."tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())))))));



CREATE POLICY "Tenant admins can manage role notification preferences" ON "public"."role_notification_preferences" USING (("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())));



CREATE POLICY "Tenant admins can manage their roles" ON "public"."roles" USING (("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())));



CREATE POLICY "Tenant admins can view tenant notification preferences" ON "public"."notification_preferences" FOR SELECT USING (("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())));



CREATE POLICY "Tenant admins can view tenant profiles" ON "public"."profiles" FOR SELECT USING (("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())));



CREATE POLICY "Tenant admins can view user roles in their tenant" ON "public"."user_roles" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE (("p"."user_id" = "user_roles"."user_id") AND ("p"."tenant_id" = "public"."get_user_tenant_id"("auth"."uid"()))))));



CREATE POLICY "Tenant admins delete activos fijos" ON "public"."activos_fijos" FOR DELETE TO "authenticated" USING (("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())));



CREATE POLICY "Tenant admins delete incapacidades" ON "public"."incapacidades" FOR DELETE TO "authenticated" USING (("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())));



CREATE POLICY "Tenant admins insert activos fijos" ON "public"."activos_fijos" FOR INSERT TO "authenticated" WITH CHECK (("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())));



CREATE POLICY "Tenant admins insert historial" ON "public"."activos_fijos_historial" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."activos_fijos" "af"
  WHERE (("af"."id" = "activos_fijos_historial"."activo_fijo_id") AND ("af"."tenant_id" = "public"."get_user_tenant_id"("auth"."uid"()))))));



CREATE POLICY "Tenant admins insert incapacidades" ON "public"."incapacidades" FOR INSERT TO "authenticated" WITH CHECK (("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())));



CREATE POLICY "Tenant admins manage portal accounts" ON "public"."employee_portal_accounts" TO "authenticated" USING (("public"."is_super_admin"("auth"."uid"()) OR ("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())))) WITH CHECK (("public"."is_super_admin"("auth"."uid"()) OR ("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"()))));



CREATE POLICY "Tenant admins update activos fijos" ON "public"."activos_fijos" FOR UPDATE TO "authenticated" USING (("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())));



CREATE POLICY "Tenant admins update incapacidades" ON "public"."incapacidades" FOR UPDATE TO "authenticated" USING (("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())));



CREATE POLICY "Tenant admins view activity log" ON "public"."employee_activity_log" FOR SELECT TO "authenticated" USING (("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())));



CREATE POLICY "Tenant admins view activos fijos" ON "public"."activos_fijos" FOR SELECT TO "authenticated" USING (("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())));



CREATE POLICY "Tenant admins view historial" ON "public"."activos_fijos_historial" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."activos_fijos" "af"
  WHERE (("af"."id" = "activos_fijos_historial"."activo_fijo_id") AND ("af"."tenant_id" = "public"."get_user_tenant_id"("auth"."uid"()))))));



CREATE POLICY "Tenant admins view incapacidades" ON "public"."incapacidades" FOR SELECT TO "authenticated" USING (("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())));



CREATE POLICY "Tenant isolation for committee_meetings" ON "public"."committee_meetings" USING ((EXISTS ( SELECT 1
   FROM "public"."committees" "c"
  WHERE (("c"."id" = "committee_meetings"."committee_id") AND (("c"."tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) OR "public"."is_super_admin"("auth"."uid"()))))));



CREATE POLICY "Tenant isolation for committee_members" ON "public"."committee_members" USING ((EXISTS ( SELECT 1
   FROM "public"."committees" "c"
  WHERE (("c"."id" = "committee_members"."committee_id") AND (("c"."tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) OR "public"."is_super_admin"("auth"."uid"()))))));



CREATE POLICY "Tenant isolation for departments" ON "public"."departments" USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) OR "public"."is_super_admin"("auth"."uid"())));



CREATE POLICY "Tenant isolation for evaluation_responses" ON "public"."evaluation_responses" USING ((EXISTS ( SELECT 1
   FROM "public"."evaluations" "e"
  WHERE (("e"."id" = "evaluation_responses"."evaluation_id") AND (("e"."tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) OR "public"."is_super_admin"("auth"."uid"()))))));



CREATE POLICY "Tenant isolation for event_participants" ON "public"."event_participants" USING ("public"."check_event_tenant"("event_id"));



CREATE POLICY "Tenant isolation for notifications" ON "public"."notifications" USING ((("user_id" = "auth"."uid"()) OR "public"."is_super_admin"("auth"."uid"())));



CREATE POLICY "Tenant isolation for positions" ON "public"."positions" USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) OR "public"."is_super_admin"("auth"."uid"())));



CREATE POLICY "Tenant isolation for template_criteria" ON "public"."evaluation_template_criteria" USING ((EXISTS ( SELECT 1
   FROM ("public"."evaluation_template_sections" "s"
     JOIN "public"."evaluation_templates" "t" ON (("t"."id" = "s"."template_id")))
  WHERE (("s"."id" = "evaluation_template_criteria"."section_id") AND (("t"."tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) OR "public"."is_super_admin"("auth"."uid"()))))));



CREATE POLICY "Tenant isolation for template_sections" ON "public"."evaluation_template_sections" USING ((EXISTS ( SELECT 1
   FROM "public"."evaluation_templates" "t"
  WHERE (("t"."id" = "evaluation_template_sections"."template_id") AND (("t"."tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) OR "public"."is_super_admin"("auth"."uid"()))))));



CREATE POLICY "Tenant members can manage employee photos" ON "public"."employee_photos" USING (("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"()))) WITH CHECK (("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())));



CREATE POLICY "Tenant members can manage their own tenant_settings" ON "public"."tenant_settings" USING (("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())));



CREATE POLICY "Tenant members can manage their own tenant_social_networks" ON "public"."tenant_social_networks" USING (("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())));



CREATE POLICY "Tenant members can view employee photos" ON "public"."employee_photos" FOR SELECT USING (("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())));



CREATE POLICY "Update annual_parameters" ON "public"."annual_parameters" FOR UPDATE USING (("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())));



CREATE POLICY "Update certificate_templates" ON "public"."certificate_templates" FOR UPDATE USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'nomina'::"text", 'editar'::"public"."permission_action"))));



CREATE POLICY "Update committees" ON "public"."committees" FOR UPDATE USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'comites'::"text", 'editar'::"public"."permission_action"))));



CREATE POLICY "Update communications" ON "public"."communications" FOR UPDATE USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'comunicaciones'::"text", 'editar'::"public"."permission_action"))));



CREATE POLICY "Update courses" ON "public"."courses" FOR UPDATE USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'cursos'::"text", 'editar'::"public"."permission_action"))));



CREATE POLICY "Update dotacion" ON "public"."dotacion" FOR UPDATE USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'dotacion'::"text", 'editar'::"public"."permission_action"))));



CREATE POLICY "Update employee_contracts" ON "public"."employee_contracts" FOR UPDATE USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'nomina'::"text", 'editar'::"public"."permission_action"))));



CREATE POLICY "Update evaluation_templates" ON "public"."evaluation_templates" FOR UPDATE USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'evaluaciones'::"text", 'editar'::"public"."permission_action"))));



CREATE POLICY "Update evaluations" ON "public"."evaluations" FOR UPDATE USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'evaluaciones'::"text", 'editar'::"public"."permission_action"))));



CREATE POLICY "Update events" ON "public"."events" FOR UPDATE USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'eventos'::"text", 'editar'::"public"."permission_action"))));



CREATE POLICY "Update exams" ON "public"."exams" FOR UPDATE USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'examenes'::"text", 'editar'::"public"."permission_action"))));



CREATE POLICY "Update payroll_items" ON "public"."payroll_items" FOR UPDATE USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'nomina'::"text", 'editar'::"public"."permission_action"))));



CREATE POLICY "Update payroll_periods" ON "public"."payroll_periods" FOR UPDATE USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'nomina'::"text", 'editar'::"public"."permission_action"))));



CREATE POLICY "Update payroll_records" ON "public"."payroll_records" FOR UPDATE USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'nomina'::"text", 'editar'::"public"."permission_action"))));



CREATE POLICY "Update regulation_acknowledgments" ON "public"."regulation_acknowledgments" FOR UPDATE USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'reglamento'::"text", 'editar'::"public"."permission_action"))));



CREATE POLICY "Update regulations" ON "public"."regulations" FOR UPDATE USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'reglamento'::"text", 'editar'::"public"."permission_action"))));



CREATE POLICY "Update vigilancias" ON "public"."vigilancias" FOR UPDATE USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'vigilancias'::"text", 'editar'::"public"."permission_action"))));



CREATE POLICY "Users can create tenant committee roles" ON "public"."committee_roles" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("is_standard" = false)));



CREATE POLICY "Users can create tenant course providers" ON "public"."course_providers" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("is_standard" = false)));



CREATE POLICY "Users can create tenant course types" ON "public"."course_types" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("is_standard" = false)));



CREATE POLICY "Users can create tenant dotacion types" ON "public"."dotacion_types" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("is_standard" = false)));



CREATE POLICY "Users can create tenant evaluation types" ON "public"."evaluation_types" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("is_standard" = false)));



CREATE POLICY "Users can create tenant event types" ON "public"."event_types" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("is_standard" = false)));



CREATE POLICY "Users can create tenant exam types" ON "public"."exam_types" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("is_standard" = false)));



CREATE POLICY "Users can create tenant vigilancia types" ON "public"."vigilancia_types" FOR INSERT WITH CHECK ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("is_standard" = false)));



CREATE POLICY "Users can delete document types" ON "public"."document_types" FOR DELETE USING (((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("is_standard" = false)) OR "public"."is_super_admin"("auth"."uid"())));



CREATE POLICY "Users can delete tenant committee roles" ON "public"."committee_roles" FOR DELETE USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("is_standard" = false)));



CREATE POLICY "Users can delete tenant course providers" ON "public"."course_providers" FOR DELETE USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("is_standard" = false)));



CREATE POLICY "Users can delete tenant course types" ON "public"."course_types" FOR DELETE USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("is_standard" = false)));



CREATE POLICY "Users can delete tenant dotacion types" ON "public"."dotacion_types" FOR DELETE USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("is_standard" = false)));



CREATE POLICY "Users can delete tenant evaluation types" ON "public"."evaluation_types" FOR DELETE USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("is_standard" = false)));



CREATE POLICY "Users can delete tenant event types" ON "public"."event_types" FOR DELETE USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("is_standard" = false)));



CREATE POLICY "Users can delete tenant exam types" ON "public"."exam_types" FOR DELETE USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("is_standard" = false)));



CREATE POLICY "Users can delete tenant vigilancia types" ON "public"."vigilancia_types" FOR DELETE USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("is_standard" = false)));



CREATE POLICY "Users can insert document types" ON "public"."document_types" FOR INSERT WITH CHECK (((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("is_standard" = false)) OR "public"."is_super_admin"("auth"."uid"())));



CREATE POLICY "Users can manage own communication reads" ON "public"."communication_reads" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can manage own notification preferences" ON "public"."notification_preferences" USING ((("user_id" = "auth"."uid"()) OR "public"."is_super_admin"("auth"."uid"())));



CREATE POLICY "Users can update committee roles" ON "public"."committee_roles" FOR UPDATE USING (((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("is_standard" = false)) OR (("is_standard" = true) AND ("public"."get_user_tenant_id"("auth"."uid"()) IS NOT NULL))));



CREATE POLICY "Users can update course providers" ON "public"."course_providers" FOR UPDATE USING (((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("is_standard" = false)) OR (("is_standard" = true) AND ("public"."get_user_tenant_id"("auth"."uid"()) IS NOT NULL))));



CREATE POLICY "Users can update course types" ON "public"."course_types" FOR UPDATE USING (((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("is_standard" = false)) OR (("is_standard" = true) AND ("public"."get_user_tenant_id"("auth"."uid"()) IS NOT NULL))));



CREATE POLICY "Users can update document types" ON "public"."document_types" FOR UPDATE USING (((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("is_standard" = false)) OR (("is_standard" = true) AND ("public"."get_user_tenant_id"("auth"."uid"()) IS NOT NULL)) OR "public"."is_super_admin"("auth"."uid"())));



CREATE POLICY "Users can update dotacion types" ON "public"."dotacion_types" FOR UPDATE USING (((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("is_standard" = false)) OR (("is_standard" = true) AND ("public"."get_user_tenant_id"("auth"."uid"()) IS NOT NULL))));



CREATE POLICY "Users can update evaluation types" ON "public"."evaluation_types" FOR UPDATE USING (((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("is_standard" = false)) OR (("is_standard" = true) AND ("public"."get_user_tenant_id"("auth"."uid"()) IS NOT NULL))));



CREATE POLICY "Users can update event types" ON "public"."event_types" FOR UPDATE USING (((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("is_standard" = false)) OR (("is_standard" = true) AND ("public"."get_user_tenant_id"("auth"."uid"()) IS NOT NULL))));



CREATE POLICY "Users can update exam types" ON "public"."exam_types" FOR UPDATE USING (((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("is_standard" = false)) OR (("is_standard" = true) AND ("public"."get_user_tenant_id"("auth"."uid"()) IS NOT NULL))));



CREATE POLICY "Users can update own profile" ON "public"."profiles" FOR UPDATE USING (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can update vigilancia types" ON "public"."vigilancia_types" FOR UPDATE USING (((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("is_standard" = false)) OR (("is_standard" = true) AND ("public"."get_user_tenant_id"("auth"."uid"()) IS NOT NULL))));



CREATE POLICY "Users can view document types" ON "public"."document_types" FOR SELECT USING ((("is_standard" = true) OR ("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) OR "public"."is_super_admin"("auth"."uid"())));



CREATE POLICY "Users can view employees in their tenant" ON "public"."employees" FOR SELECT USING (("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())));



CREATE POLICY "Users can view own profile" ON "public"."profiles" FOR SELECT USING (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can view role permissions for their tenant" ON "public"."role_permissions" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."roles" "r"
  WHERE (("r"."id" = "role_permissions"."role_id") AND ("r"."tenant_id" = "public"."get_user_tenant_id"("auth"."uid"()))))));



CREATE POLICY "Users can view tenant committee roles" ON "public"."committee_roles" FOR SELECT USING (("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())));



CREATE POLICY "Users can view tenant course providers" ON "public"."course_providers" FOR SELECT USING (("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())));



CREATE POLICY "Users can view tenant course types" ON "public"."course_types" FOR SELECT USING (("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())));



CREATE POLICY "Users can view tenant dotacion types" ON "public"."dotacion_types" FOR SELECT USING (("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())));



CREATE POLICY "Users can view tenant evaluation types" ON "public"."evaluation_types" FOR SELECT USING (("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())));



CREATE POLICY "Users can view tenant event types" ON "public"."event_types" FOR SELECT USING (("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())));



CREATE POLICY "Users can view tenant exam types" ON "public"."exam_types" FOR SELECT USING (("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())));



CREATE POLICY "Users can view tenant vigilancia types" ON "public"."vigilancia_types" FOR SELECT USING (("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())));



CREATE POLICY "Users can view their own permissions" ON "public"."user_permissions" FOR SELECT USING (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can view their own roles" ON "public"."user_roles" FOR SELECT USING (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can view their tenant audit logs" ON "public"."audit_log" FOR SELECT USING (("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())));



CREATE POLICY "Users with permission can manage employees" ON "public"."employees" USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'empleados'::"text", 'crear'::"public"."permission_action") OR "public"."has_permission"("auth"."uid"(), 'empleados'::"text", 'editar'::"public"."permission_action") OR "public"."has_permission"("auth"."uid"(), 'empleados'::"text", 'eliminar'::"public"."permission_action"))));



CREATE POLICY "View annual_parameters" ON "public"."annual_parameters" FOR SELECT USING (("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())));



CREATE POLICY "View certificate_templates" ON "public"."certificate_templates" FOR SELECT USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'nomina'::"text", 'ver'::"public"."permission_action"))));



CREATE POLICY "View committees" ON "public"."committees" FOR SELECT USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'comites'::"text", 'ver'::"public"."permission_action"))));



CREATE POLICY "View communications" ON "public"."communications" FOR SELECT USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'comunicaciones'::"text", 'ver'::"public"."permission_action"))));



CREATE POLICY "View courses" ON "public"."courses" FOR SELECT USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'cursos'::"text", 'ver'::"public"."permission_action"))));



CREATE POLICY "View dotacion" ON "public"."dotacion" FOR SELECT USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'dotacion'::"text", 'ver'::"public"."permission_action"))));



CREATE POLICY "View employee_contracts" ON "public"."employee_contracts" FOR SELECT USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'nomina'::"text", 'ver'::"public"."permission_action"))));



CREATE POLICY "View evaluation_templates" ON "public"."evaluation_templates" FOR SELECT USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'evaluaciones'::"text", 'ver'::"public"."permission_action"))));



CREATE POLICY "View evaluations" ON "public"."evaluations" FOR SELECT USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'evaluaciones'::"text", 'ver'::"public"."permission_action"))));



CREATE POLICY "View events" ON "public"."events" FOR SELECT USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'eventos'::"text", 'ver'::"public"."permission_action"))));



CREATE POLICY "View evidences" ON "public"."evidences" FOR SELECT TO "authenticated" USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), "module", 'ver'::"public"."permission_action"))));



CREATE POLICY "View exams" ON "public"."exams" FOR SELECT USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'examenes'::"text", 'ver'::"public"."permission_action"))));



CREATE POLICY "View payroll_items" ON "public"."payroll_items" FOR SELECT USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'nomina'::"text", 'ver'::"public"."permission_action"))));



CREATE POLICY "View payroll_periods" ON "public"."payroll_periods" FOR SELECT USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'nomina'::"text", 'ver'::"public"."permission_action"))));



CREATE POLICY "View payroll_records" ON "public"."payroll_records" FOR SELECT USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'nomina'::"text", 'ver'::"public"."permission_action"))));



CREATE POLICY "View regulation_acknowledgments" ON "public"."regulation_acknowledgments" FOR SELECT USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'reglamento'::"text", 'ver'::"public"."permission_action"))));



CREATE POLICY "View regulations" ON "public"."regulations" FOR SELECT USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'reglamento'::"text", 'ver'::"public"."permission_action"))));



CREATE POLICY "View signatures" ON "public"."signatures" FOR SELECT USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'firmas'::"text", 'ver'::"public"."permission_action"))));



CREATE POLICY "View standard or own tenant activo fijo estados" ON "public"."activo_fijo_estados" FOR SELECT TO "authenticated" USING ((("is_standard" = true) OR ("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"()))));



CREATE POLICY "View standard or own tenant activo fijo marcas" ON "public"."activo_fijo_marcas" FOR SELECT TO "authenticated" USING ((("is_standard" = true) OR ("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"()))));



CREATE POLICY "View standard or own tenant activo fijo tipos" ON "public"."activo_fijo_tipos" FOR SELECT TO "authenticated" USING ((("is_standard" = true) OR ("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"()))));



CREATE POLICY "View standard or own tenant incapacidad types" ON "public"."incapacidad_types" FOR SELECT TO "authenticated" USING ((("is_standard" = true) OR ("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"()))));



CREATE POLICY "View vigilancias" ON "public"."vigilancias" FOR SELECT USING ((("tenant_id" = "public"."get_user_tenant_id"("auth"."uid"())) AND ("public"."is_super_admin"("auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'vigilancias'::"text", 'ver'::"public"."permission_action"))));



ALTER TABLE "public"."activo_fijo_estados" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."activo_fijo_marcas" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."activo_fijo_tipos" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."activos_fijos" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."activos_fijos_historial" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."annual_parameters" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."audit_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."certificate_templates" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."committee_meetings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."committee_members" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."committee_roles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."committees" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."communication_reads" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."communications" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."course_providers" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."course_types" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."courses" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."departments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."distribution_list_members" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."distribution_lists" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."document_types" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."dotacion" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."dotacion_types" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."employee_activity_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."employee_contracts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."employee_photos" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."employee_portal_accounts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."employees" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."evaluation_responses" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."evaluation_template_criteria" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."evaluation_template_sections" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."evaluation_templates" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."evaluation_types" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."evaluations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."event_participants" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."event_types" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."evidences" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."exam_types" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."exams" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."incapacidad_types" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."incapacidades" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."modules" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."notification_preferences" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."notifications" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."payroll_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."payroll_periods" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."payroll_records" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."pending_summary_notifications" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."permissions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."positions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."regulation_acknowledgments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."regulations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."role_notification_preferences" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."role_permissions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."roles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."signatures" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."tenant_settings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."tenant_social_networks" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_permissions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_roles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."vigilancia_types" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."vigilancias" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";






















































































































































GRANT ALL ON FUNCTION "public"."calculate_evaluation_score"("_evaluation_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."calculate_evaluation_score"("_evaluation_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."calculate_evaluation_score"("_evaluation_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."check_event_tenant"("p_event_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."check_event_tenant"("p_event_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."check_event_tenant"("p_event_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."check_user_exists_in_auth_rpc"("p_email" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."check_user_exists_in_auth_rpc"("p_email" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."check_user_exists_in_auth_rpc"("p_email" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."count_active_employees_for_billing"("p_tenant_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."count_active_employees_for_billing"("p_tenant_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."count_active_employees_for_billing"("p_tenant_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_tenant_with_admin"("p_tenant_id" "uuid", "p_user_id" "uuid", "p_platform_id" "uuid", "p_tenant_name" "text", "p_country_id" "text", "p_email" "text", "p_currency_id" "uuid", "p_timezone" "text", "p_phone" "text", "p_address" "text", "p_website" "text", "p_latitude" numeric, "p_longitude" numeric, "p_whatsapp_phone" "text", "p_legal_name" "text", "p_tax_id" "text", "p_einvoicing_email" "text", "p_physical_address_line1" "text", "p_physical_address_line2" "text", "p_physical_city" "text", "p_physical_state" "text", "p_physical_postal_code" "text", "p_default_language_code" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_tenant_with_admin"("p_tenant_id" "uuid", "p_user_id" "uuid", "p_platform_id" "uuid", "p_tenant_name" "text", "p_country_id" "text", "p_email" "text", "p_currency_id" "uuid", "p_timezone" "text", "p_phone" "text", "p_address" "text", "p_website" "text", "p_latitude" numeric, "p_longitude" numeric, "p_whatsapp_phone" "text", "p_legal_name" "text", "p_tax_id" "text", "p_einvoicing_email" "text", "p_physical_address_line1" "text", "p_physical_address_line2" "text", "p_physical_city" "text", "p_physical_state" "text", "p_physical_postal_code" "text", "p_default_language_code" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_tenant_with_admin"("p_tenant_id" "uuid", "p_user_id" "uuid", "p_platform_id" "uuid", "p_tenant_name" "text", "p_country_id" "text", "p_email" "text", "p_currency_id" "uuid", "p_timezone" "text", "p_phone" "text", "p_address" "text", "p_website" "text", "p_latitude" numeric, "p_longitude" numeric, "p_whatsapp_phone" "text", "p_legal_name" "text", "p_tax_id" "text", "p_einvoicing_email" "text", "p_physical_address_line1" "text", "p_physical_address_line2" "text", "p_physical_city" "text", "p_physical_state" "text", "p_physical_postal_code" "text", "p_default_language_code" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_current_employee_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_current_employee_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_current_employee_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_dashboard_stats"("p_tenant_id" "uuid", "p_reference_date" "date", "p_timezone" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_dashboard_stats"("p_tenant_id" "uuid", "p_reference_date" "date", "p_timezone" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_dashboard_stats"("p_tenant_id" "uuid", "p_reference_date" "date", "p_timezone" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_nexuhr_storage_usage"("p_tenant_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_nexuhr_storage_usage"("p_tenant_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_nexuhr_storage_usage"("p_tenant_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_portal_permissions"("p_tenant_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_portal_permissions"("p_tenant_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_portal_permissions"("p_tenant_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_tenant_by_portal_slug"("p_slug" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_tenant_by_portal_slug"("p_slug" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_tenant_by_portal_slug"("p_slug" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_user_notification_preferences"("_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_user_notification_preferences"("_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_notification_preferences"("_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_user_tenant_id"("_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_user_tenant_id"("_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_tenant_id"("_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."has_permission"("_user_id" "uuid", "_module_code" "text", "_action" "public"."permission_action") TO "anon";
GRANT ALL ON FUNCTION "public"."has_permission"("_user_id" "uuid", "_module_code" "text", "_action" "public"."permission_action") TO "authenticated";
GRANT ALL ON FUNCTION "public"."has_permission"("_user_id" "uuid", "_module_code" "text", "_action" "public"."permission_action") TO "service_role";



GRANT ALL ON FUNCTION "public"."has_role"("_user_id" "uuid", "_role" "public"."app_role") TO "anon";
GRANT ALL ON FUNCTION "public"."has_role"("_user_id" "uuid", "_role" "public"."app_role") TO "authenticated";
GRANT ALL ON FUNCTION "public"."has_role"("_user_id" "uuid", "_role" "public"."app_role") TO "service_role";



GRANT ALL ON FUNCTION "public"."is_super_admin"("_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_super_admin"("_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_super_admin"("_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."portal_account_mark_password_changed"("p_account_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."portal_account_mark_password_changed"("p_account_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."portal_account_mark_password_changed"("p_account_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."resolve_employee_login"("p_documento" "text", "p_tenant_slug" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."resolve_employee_login"("p_documento" "text", "p_tenant_slug" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."resolve_employee_login"("p_documento" "text", "p_tenant_slug" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."revoke_portal_on_retire"() TO "anon";
GRANT ALL ON FUNCTION "public"."revoke_portal_on_retire"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."revoke_portal_on_retire"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_super_admin_on_role_change"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_super_admin_on_role_change"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_super_admin_on_role_change"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "service_role";


















GRANT ALL ON TABLE "public"."activo_fijo_estados" TO "anon";
GRANT ALL ON TABLE "public"."activo_fijo_estados" TO "authenticated";
GRANT ALL ON TABLE "public"."activo_fijo_estados" TO "service_role";



GRANT ALL ON TABLE "public"."activo_fijo_marcas" TO "anon";
GRANT ALL ON TABLE "public"."activo_fijo_marcas" TO "authenticated";
GRANT ALL ON TABLE "public"."activo_fijo_marcas" TO "service_role";



GRANT ALL ON TABLE "public"."activo_fijo_tipos" TO "anon";
GRANT ALL ON TABLE "public"."activo_fijo_tipos" TO "authenticated";
GRANT ALL ON TABLE "public"."activo_fijo_tipos" TO "service_role";



GRANT ALL ON TABLE "public"."activos_fijos" TO "anon";
GRANT ALL ON TABLE "public"."activos_fijos" TO "authenticated";
GRANT ALL ON TABLE "public"."activos_fijos" TO "service_role";



GRANT ALL ON TABLE "public"."activos_fijos_historial" TO "anon";
GRANT ALL ON TABLE "public"."activos_fijos_historial" TO "authenticated";
GRANT ALL ON TABLE "public"."activos_fijos_historial" TO "service_role";



GRANT ALL ON TABLE "public"."annual_parameters" TO "anon";
GRANT ALL ON TABLE "public"."annual_parameters" TO "authenticated";
GRANT ALL ON TABLE "public"."annual_parameters" TO "service_role";



GRANT ALL ON TABLE "public"."audit_log" TO "anon";
GRANT ALL ON TABLE "public"."audit_log" TO "authenticated";
GRANT ALL ON TABLE "public"."audit_log" TO "service_role";



GRANT ALL ON TABLE "public"."certificate_templates" TO "anon";
GRANT ALL ON TABLE "public"."certificate_templates" TO "authenticated";
GRANT ALL ON TABLE "public"."certificate_templates" TO "service_role";



GRANT ALL ON TABLE "public"."committee_meetings" TO "anon";
GRANT ALL ON TABLE "public"."committee_meetings" TO "authenticated";
GRANT ALL ON TABLE "public"."committee_meetings" TO "service_role";



GRANT ALL ON TABLE "public"."committee_members" TO "anon";
GRANT ALL ON TABLE "public"."committee_members" TO "authenticated";
GRANT ALL ON TABLE "public"."committee_members" TO "service_role";



GRANT ALL ON TABLE "public"."committee_roles" TO "anon";
GRANT ALL ON TABLE "public"."committee_roles" TO "authenticated";
GRANT ALL ON TABLE "public"."committee_roles" TO "service_role";



GRANT ALL ON TABLE "public"."committees" TO "anon";
GRANT ALL ON TABLE "public"."committees" TO "authenticated";
GRANT ALL ON TABLE "public"."committees" TO "service_role";



GRANT ALL ON TABLE "public"."communication_reads" TO "anon";
GRANT ALL ON TABLE "public"."communication_reads" TO "authenticated";
GRANT ALL ON TABLE "public"."communication_reads" TO "service_role";



GRANT ALL ON TABLE "public"."communications" TO "anon";
GRANT ALL ON TABLE "public"."communications" TO "authenticated";
GRANT ALL ON TABLE "public"."communications" TO "service_role";



GRANT ALL ON TABLE "public"."course_providers" TO "anon";
GRANT ALL ON TABLE "public"."course_providers" TO "authenticated";
GRANT ALL ON TABLE "public"."course_providers" TO "service_role";



GRANT ALL ON TABLE "public"."course_types" TO "anon";
GRANT ALL ON TABLE "public"."course_types" TO "authenticated";
GRANT ALL ON TABLE "public"."course_types" TO "service_role";



GRANT ALL ON TABLE "public"."courses" TO "anon";
GRANT ALL ON TABLE "public"."courses" TO "authenticated";
GRANT ALL ON TABLE "public"."courses" TO "service_role";



GRANT ALL ON TABLE "public"."departments" TO "anon";
GRANT ALL ON TABLE "public"."departments" TO "authenticated";
GRANT ALL ON TABLE "public"."departments" TO "service_role";



GRANT ALL ON TABLE "public"."distribution_list_members" TO "anon";
GRANT ALL ON TABLE "public"."distribution_list_members" TO "authenticated";
GRANT ALL ON TABLE "public"."distribution_list_members" TO "service_role";



GRANT ALL ON TABLE "public"."distribution_lists" TO "anon";
GRANT ALL ON TABLE "public"."distribution_lists" TO "authenticated";
GRANT ALL ON TABLE "public"."distribution_lists" TO "service_role";



GRANT ALL ON TABLE "public"."document_types" TO "anon";
GRANT ALL ON TABLE "public"."document_types" TO "authenticated";
GRANT ALL ON TABLE "public"."document_types" TO "service_role";



GRANT ALL ON TABLE "public"."dotacion" TO "anon";
GRANT ALL ON TABLE "public"."dotacion" TO "authenticated";
GRANT ALL ON TABLE "public"."dotacion" TO "service_role";



GRANT ALL ON TABLE "public"."dotacion_types" TO "anon";
GRANT ALL ON TABLE "public"."dotacion_types" TO "authenticated";
GRANT ALL ON TABLE "public"."dotacion_types" TO "service_role";



GRANT ALL ON TABLE "public"."employee_activity_log" TO "anon";
GRANT ALL ON TABLE "public"."employee_activity_log" TO "authenticated";
GRANT ALL ON TABLE "public"."employee_activity_log" TO "service_role";



GRANT ALL ON TABLE "public"."employee_contracts" TO "anon";
GRANT ALL ON TABLE "public"."employee_contracts" TO "authenticated";
GRANT ALL ON TABLE "public"."employee_contracts" TO "service_role";



GRANT ALL ON TABLE "public"."employee_photos" TO "anon";
GRANT ALL ON TABLE "public"."employee_photos" TO "authenticated";
GRANT ALL ON TABLE "public"."employee_photos" TO "service_role";



GRANT ALL ON TABLE "public"."employee_portal_accounts" TO "anon";
GRANT ALL ON TABLE "public"."employee_portal_accounts" TO "authenticated";
GRANT ALL ON TABLE "public"."employee_portal_accounts" TO "service_role";



GRANT ALL ON TABLE "public"."employees" TO "anon";
GRANT ALL ON TABLE "public"."employees" TO "authenticated";
GRANT ALL ON TABLE "public"."employees" TO "service_role";



GRANT ALL ON TABLE "public"."evaluation_responses" TO "anon";
GRANT ALL ON TABLE "public"."evaluation_responses" TO "authenticated";
GRANT ALL ON TABLE "public"."evaluation_responses" TO "service_role";



GRANT ALL ON TABLE "public"."evaluation_template_criteria" TO "anon";
GRANT ALL ON TABLE "public"."evaluation_template_criteria" TO "authenticated";
GRANT ALL ON TABLE "public"."evaluation_template_criteria" TO "service_role";



GRANT ALL ON TABLE "public"."evaluation_template_sections" TO "anon";
GRANT ALL ON TABLE "public"."evaluation_template_sections" TO "authenticated";
GRANT ALL ON TABLE "public"."evaluation_template_sections" TO "service_role";



GRANT ALL ON TABLE "public"."evaluation_templates" TO "anon";
GRANT ALL ON TABLE "public"."evaluation_templates" TO "authenticated";
GRANT ALL ON TABLE "public"."evaluation_templates" TO "service_role";



GRANT ALL ON TABLE "public"."evaluation_types" TO "anon";
GRANT ALL ON TABLE "public"."evaluation_types" TO "authenticated";
GRANT ALL ON TABLE "public"."evaluation_types" TO "service_role";



GRANT ALL ON TABLE "public"."evaluations" TO "anon";
GRANT ALL ON TABLE "public"."evaluations" TO "authenticated";
GRANT ALL ON TABLE "public"."evaluations" TO "service_role";



GRANT ALL ON TABLE "public"."event_participants" TO "anon";
GRANT ALL ON TABLE "public"."event_participants" TO "authenticated";
GRANT ALL ON TABLE "public"."event_participants" TO "service_role";



GRANT ALL ON TABLE "public"."event_types" TO "anon";
GRANT ALL ON TABLE "public"."event_types" TO "authenticated";
GRANT ALL ON TABLE "public"."event_types" TO "service_role";



GRANT ALL ON TABLE "public"."events" TO "anon";
GRANT ALL ON TABLE "public"."events" TO "authenticated";
GRANT ALL ON TABLE "public"."events" TO "service_role";



GRANT ALL ON TABLE "public"."evidences" TO "anon";
GRANT ALL ON TABLE "public"."evidences" TO "authenticated";
GRANT ALL ON TABLE "public"."evidences" TO "service_role";



GRANT ALL ON TABLE "public"."exam_types" TO "anon";
GRANT ALL ON TABLE "public"."exam_types" TO "authenticated";
GRANT ALL ON TABLE "public"."exam_types" TO "service_role";



GRANT ALL ON TABLE "public"."exams" TO "anon";
GRANT ALL ON TABLE "public"."exams" TO "authenticated";
GRANT ALL ON TABLE "public"."exams" TO "service_role";



GRANT ALL ON TABLE "public"."incapacidad_types" TO "anon";
GRANT ALL ON TABLE "public"."incapacidad_types" TO "authenticated";
GRANT ALL ON TABLE "public"."incapacidad_types" TO "service_role";



GRANT ALL ON TABLE "public"."incapacidades" TO "anon";
GRANT ALL ON TABLE "public"."incapacidades" TO "authenticated";
GRANT ALL ON TABLE "public"."incapacidades" TO "service_role";



GRANT ALL ON TABLE "public"."modules" TO "anon";
GRANT ALL ON TABLE "public"."modules" TO "authenticated";
GRANT ALL ON TABLE "public"."modules" TO "service_role";



GRANT ALL ON TABLE "public"."notification_preferences" TO "anon";
GRANT ALL ON TABLE "public"."notification_preferences" TO "authenticated";
GRANT ALL ON TABLE "public"."notification_preferences" TO "service_role";



GRANT ALL ON TABLE "public"."notifications" TO "anon";
GRANT ALL ON TABLE "public"."notifications" TO "authenticated";
GRANT ALL ON TABLE "public"."notifications" TO "service_role";



GRANT ALL ON TABLE "public"."payroll_items" TO "anon";
GRANT ALL ON TABLE "public"."payroll_items" TO "authenticated";
GRANT ALL ON TABLE "public"."payroll_items" TO "service_role";



GRANT ALL ON TABLE "public"."payroll_periods" TO "anon";
GRANT ALL ON TABLE "public"."payroll_periods" TO "authenticated";
GRANT ALL ON TABLE "public"."payroll_periods" TO "service_role";



GRANT ALL ON TABLE "public"."payroll_records" TO "anon";
GRANT ALL ON TABLE "public"."payroll_records" TO "authenticated";
GRANT ALL ON TABLE "public"."payroll_records" TO "service_role";



GRANT ALL ON TABLE "public"."pending_summary_notifications" TO "anon";
GRANT ALL ON TABLE "public"."pending_summary_notifications" TO "authenticated";
GRANT ALL ON TABLE "public"."pending_summary_notifications" TO "service_role";



GRANT ALL ON TABLE "public"."permissions" TO "anon";
GRANT ALL ON TABLE "public"."permissions" TO "authenticated";
GRANT ALL ON TABLE "public"."permissions" TO "service_role";



GRANT ALL ON TABLE "public"."positions" TO "anon";
GRANT ALL ON TABLE "public"."positions" TO "authenticated";
GRANT ALL ON TABLE "public"."positions" TO "service_role";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON TABLE "public"."regulation_acknowledgments" TO "anon";
GRANT ALL ON TABLE "public"."regulation_acknowledgments" TO "authenticated";
GRANT ALL ON TABLE "public"."regulation_acknowledgments" TO "service_role";



GRANT ALL ON TABLE "public"."regulations" TO "anon";
GRANT ALL ON TABLE "public"."regulations" TO "authenticated";
GRANT ALL ON TABLE "public"."regulations" TO "service_role";



GRANT ALL ON TABLE "public"."role_notification_preferences" TO "anon";
GRANT ALL ON TABLE "public"."role_notification_preferences" TO "authenticated";
GRANT ALL ON TABLE "public"."role_notification_preferences" TO "service_role";



GRANT ALL ON TABLE "public"."role_permissions" TO "anon";
GRANT ALL ON TABLE "public"."role_permissions" TO "authenticated";
GRANT ALL ON TABLE "public"."role_permissions" TO "service_role";



GRANT ALL ON TABLE "public"."roles" TO "anon";
GRANT ALL ON TABLE "public"."roles" TO "authenticated";
GRANT ALL ON TABLE "public"."roles" TO "service_role";



GRANT ALL ON TABLE "public"."signatures" TO "anon";
GRANT ALL ON TABLE "public"."signatures" TO "authenticated";
GRANT ALL ON TABLE "public"."signatures" TO "service_role";



GRANT ALL ON TABLE "public"."tenant_settings" TO "anon";
GRANT ALL ON TABLE "public"."tenant_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."tenant_settings" TO "service_role";



GRANT ALL ON TABLE "public"."tenant_social_networks" TO "anon";
GRANT ALL ON TABLE "public"."tenant_social_networks" TO "authenticated";
GRANT ALL ON TABLE "public"."tenant_social_networks" TO "service_role";



GRANT ALL ON TABLE "public"."tenants" TO "anon";
GRANT ALL ON TABLE "public"."tenants" TO "authenticated";
GRANT ALL ON TABLE "public"."tenants" TO "service_role";



GRANT ALL ON TABLE "public"."user_permissions" TO "anon";
GRANT ALL ON TABLE "public"."user_permissions" TO "authenticated";
GRANT ALL ON TABLE "public"."user_permissions" TO "service_role";



GRANT ALL ON TABLE "public"."user_roles" TO "anon";
GRANT ALL ON TABLE "public"."user_roles" TO "authenticated";
GRANT ALL ON TABLE "public"."user_roles" TO "service_role";



GRANT ALL ON TABLE "public"."vigilancia_types" TO "anon";
GRANT ALL ON TABLE "public"."vigilancia_types" TO "authenticated";
GRANT ALL ON TABLE "public"."vigilancia_types" TO "service_role";



GRANT ALL ON TABLE "public"."vigilancias" TO "anon";
GRANT ALL ON TABLE "public"."vigilancias" TO "authenticated";
GRANT ALL ON TABLE "public"."vigilancias" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";































