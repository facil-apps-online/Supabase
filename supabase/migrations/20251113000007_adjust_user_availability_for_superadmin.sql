CREATE OR REPLACE FUNCTION public.check_user_availability(
    p_item_id uuid,
    p_item_type text,
    p_appointment_date date,
    p_appointment_time time,
    p_duration_minutes integer,
    p_branch_id uuid,
    p_tenant_id uuid,
    p_assigned_user_id uuid
)
RETURNS TABLE (
    user_id uuid,
    commission_rate numeric,
    first_name text,
    last_name text,
    is_active boolean
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_day_of_week INTEGER := EXTRACT(DOW FROM p_appointment_date);
    v_branch_timezone TEXT;
    v_appointment_start_utc TIMESTAMPTZ;
    v_appointment_end_utc TIMESTAMPTZ;
    v_appointment_range TSRANGE;
BEGIN
    -- 1. Get the branch timezone.
    SELECT timezone INTO v_branch_timezone FROM public.branches WHERE id = p_branch_id;
    IF v_branch_timezone IS NULL THEN
        -- Fallback to tenant timezone if branch timezone is not set.
        SELECT default_timezone INTO v_branch_timezone FROM public.tenants WHERE id = p_tenant_id;
        IF v_branch_timezone IS NULL THEN
            v_branch_timezone := 'UTC';
        END IF;
    END IF;

    -- 2. Correctly construct the appointment timestamp in UTC from DATE and TIME parts.
    v_appointment_start_utc := (p_appointment_date::TEXT || ' ' || p_appointment_time::TEXT)::TIMESTAMP AT TIME ZONE v_branch_timezone AT TIME ZONE 'UTC';
    v_appointment_end_utc := v_appointment_start_utc + (p_duration_minutes || ' minutes')::INTERVAL;
    v_appointment_range := TSRANGE(v_appointment_start_utc::TIMESTAMP WITHOUT TIME ZONE, v_appointment_end_utc::TIMESTAMP WITHOUT TIME ZONE);

    -- Main Query
    RETURN QUERY
    SELECT
        tu.user_id,
        COALESCE(suc.commission_rate, tu.default_service_commission_rate, 0.00) AS commission_rate,
        tu.first_name,
        tu.last_name,
        (tu.status = 'active') AS is_active
    FROM
        public.get_tenant_users(p_tenant_id) tu -- Source of truth for user data, including timezone
    LEFT JOIN LATERAL (
        SELECT suc.commission_rate
        FROM public.service_user_commissions suc
        WHERE suc.user_id = tu.user_id
          AND suc.branch_id = p_branch_id
          AND suc.tenant_id = p_tenant_id
          AND (
            (p_item_type = 'service' AND suc.service_id = p_item_id)
            OR
            (p_item_type = 'combo' AND suc.service_id IN (
                SELECT ci.service_id FROM public.combo_items ci WHERE ci.combo_id = p_item_id AND ci.service_id IS NOT NULL
            ))
          )
        ORDER BY suc.created_at DESC
        LIMIT 1
    ) suc ON TRUE
    WHERE
        (tu.branch_id = p_branch_id OR tu.role_name = 'tenant_super_admin')
        AND tu.status = 'active'
        AND (
            ( -- Main availability logic block
                EXISTS (
                    SELECT 1
                    FROM public.user_schedules us
                    WHERE us.user_id = tu.user_id
                      AND us.day_of_week = v_day_of_week
                      AND us.is_active = TRUE
                      AND us.tenant_id = p_tenant_id
                      AND (us.branch_id IS NULL OR us.branch_id = p_branch_id)
                      AND TSRANGE(
                            ( (p_appointment_date::TEXT || ' ' || us.start_time::TEXT)::TIMESTAMP AT TIME ZONE COALESCE(tu.timezone, v_branch_timezone) AT TIME ZONE 'UTC' )::TIMESTAMP WITHOUT TIME ZONE,
                            ( (p_appointment_date::TEXT || ' ' || us.end_time::TEXT)::TIMESTAMP AT TIME ZONE COALESCE(tu.timezone, v_branch_timezone) AT TIME ZONE 'UTC' )::TIMESTAMP WITHOUT TIME ZONE
                          ) @> v_appointment_range
                )
                AND NOT EXISTS (
                    SELECT 1
                    FROM public.user_time_off uto
                    WHERE uto.user_id = tu.user_id
                      AND uto.status = 'approved'
                      AND uto.tenant_id = p_tenant_id
                      AND (uto.branch_id IS NULL OR uto.branch_id = p_branch_id)
                      AND v_appointment_range && TSRANGE(
                          uto.start_date AT TIME ZONE 'UTC', 
                          uto.end_date AT TIME ZONE 'UTC'
                      )
                )
            )
            OR (tu.user_id = p_assigned_user_id AND p_assigned_user_id IS NOT NULL)
        );
END;
$$;