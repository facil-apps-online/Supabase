DROP FUNCTION IF EXISTS public.check_user_availability(uuid, text, date, time without time zone, integer, uuid, uuid, uuid);

CREATE OR REPLACE FUNCTION public.check_user_availability(
    p_item_id uuid,
    p_item_type text,
    p_appointment_date date,
    p_appointment_time time without time zone,
    p_duration_minutes integer,
    p_branch_id uuid,
    p_tenant_id uuid,
    p_assigned_user_id uuid,
    p_client_id uuid
)
RETURNS TABLE(user_id uuid, commission_rate numeric, first_name text, last_name text, is_active boolean, role_name text)
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

    -- Main Query with CTE for ranking assignments
    RETURN QUERY
    WITH RankedAssignments AS (
        SELECT
            u.user_id,
            u.first_name,
            u.last_name,
            u.status,
            u.branch_id,
            u.role_name,
            u.timezone,
            u.default_service_commission_rate,
            ROW_NUMBER() OVER(PARTITION BY u.user_id ORDER BY
                CASE
                    WHEN cp.user_id IS NOT NULL THEN 0 -- 0. Favorite professionals
                    WHEN u.branch_id = p_branch_id THEN 1 -- 1. Assignment in the correct branch
                    WHEN u.role_name = 'tenant_super_admin' THEN 2 -- 2. Super admin
                    ELSE 3
                END
            ) as rn
        FROM
            public.get_tenant_users(p_tenant_id) u
        LEFT JOIN public.client_professionals cp ON u.user_id = cp.user_id AND cp.client_id = p_client_id
        WHERE u.status = 'active'
    )
    SELECT
        tu.user_id,
        COALESCE(suc.commission_rate, tu.default_service_commission_rate, 0.00) AS commission_rate,
        tu.first_name,
        tu.last_name,
        (tu.status = 'active') AS is_active,
        tu.role_name -- Added as requested
    FROM
        RankedAssignments tu
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
        tu.rn = 1 -- Take only the highest-priority assignment for each user
        AND ( -- The rest of the availability logic
            (
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