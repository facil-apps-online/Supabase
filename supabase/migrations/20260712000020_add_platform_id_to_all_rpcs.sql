-- Migration: 20260712000020_add_platform_id_to_all_rpcs.sql
-- Description: Injects p_platform_id to all remaining RPCs that take p_tenant_id.

DROP FUNCTION IF EXISTS "public"."activate_branches_batch"("p_tenant_id" "uuid", "p_branch_ids" "uuid"[]);

CREATE OR REPLACE FUNCTION "public"."activate_branches_batch"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_branch_ids" "uuid"[]) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_branch_id UUID;
    v_branch RECORD;
    v_subscription RECORD;
    v_price_history RECORD;
    v_subscription_status TEXT;
    v_days_in_cycle INT;
    v_days_remaining INT;
    v_daily_rate NUMERIC;
    v_prorated_amount NUMERIC;
    v_branch_price NUMERIC;
    
    v_activated_count INT := 0;
    v_failed_count INT := 0;
    v_total_prorated_amount NUMERIC := 0;
    v_details JSONB[] := ARRAY[]::JSONB[];
    v_error_message TEXT;
BEGIN
    -- Step 1: Verify the tenant has an active subscription once
    SELECT status INTO v_subscription_status FROM public.get_tenant_subscription_status(p_tenant_id, p_platform_id);
    IF v_subscription_status != 'activo' THEN
        RETURN jsonb_build_object(
            'success', false, 
            'message', 'Cannot activate branches. Tenant subscription status is: ' || v_subscription_status,
            'activated_count', 0,
            'failed_count', array_length(p_branch_ids, 1),
            'total_prorated_amount', 0,
            'details', '[]'::JSONB
        );
    END IF;

    -- Step 2: Get the latest subscription record once
    SELECT * INTO v_subscription 
    FROM public.tenant_subscriptions 
    WHERE tenant_id = p_tenant_id AND platform_id = p_platform_id 
    ORDER BY end_date DESC NULLS FIRST 
    LIMIT 1;
    
    IF v_subscription IS NULL THEN 
        RETURN jsonb_build_object(
            'success', false, 
            'message', 'No active subscription record found for the tenant.',
            'activated_count', 0,
            'failed_count', array_length(p_branch_ids, 1),
            'total_prorated_amount', 0,
            'details', '[]'::JSONB
        );
    END IF;

    -- Step 3: Loop through each branch ID
    FOREACH v_branch_id IN ARRAY p_branch_ids
    LOOP
        BEGIN
            -- Step 3a: Validate the branch
            SELECT * INTO v_branch FROM public.branches WHERE id = v_branch_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;
            IF v_branch IS NULL THEN RAISE EXCEPTION 'Branch not found or access denied'; END IF;
            IF v_branch.status <> 'pending_activation' THEN RAISE EXCEPTION 'Branch is not pending activation'; END IF;

            -- Step 3b: Get the price for the plan
            SELECT extra_branch_price_cop INTO v_branch_price
            FROM public.plan_price_history
            WHERE subscription_plan_id = v_subscription.subscription_plan_id AND effective_date <= NOW()
            ORDER BY effective_date DESC
            LIMIT 1;

            IF v_branch_price IS NULL OR v_branch_price <= 0 THEN 
                RAISE EXCEPTION 'Could not find a valid price for the branch.'; 
            END IF;

            -- Step 3c: Proration Calculation
            IF v_subscription.end_date IS NULL THEN
                RAISE EXCEPTION 'The current subscription has no end date.';
            ELSE
                v_days_in_cycle := v_subscription.end_date::date - v_subscription.start_date::date;
                v_days_remaining := v_subscription.end_date::date - NOW()::date;
                v_prorated_amount := 0;
                IF v_days_remaining > 0 AND v_days_in_cycle > 0 THEN
                    v_daily_rate := v_branch_price / v_days_in_cycle;
                    v_prorated_amount := v_daily_rate * v_days_remaining;
                END IF;
            END IF;

            -- Step 3d: Activate the branch and create the asset
            UPDATE public.branches SET status = 'active', activated_at = NOW() WHERE id = v_branch_id;
            INSERT INTO public.subscription_assets (tenant_subscription_id, asset_type, asset_reference_id, status, price_at_addition)
            VALUES (v_subscription.id, 'branch', v_branch_id, 'active', v_branch_price);

            -- Step 3e: Log success
            v_activated_count := v_activated_count + 1;
            v_total_prorated_amount := v_total_prorated_amount + round(v_prorated_amount, 2);
            v_details := array_append(v_details, jsonb_build_object(
                'branch_id', v_branch_id, 
                'status', 'success', 
                'amount_charged', round(v_prorated_amount, 2)
            ));

        EXCEPTION
            WHEN OTHERS THEN
                GET STACKED DIAGNOSTICS v_error_message = MESSAGE_TEXT;
                v_failed_count := v_failed_count + 1;
                v_details := array_append(v_details, jsonb_build_object(
                    'branch_id', v_branch_id, 
                    'status', 'failed', 
                    'error', v_error_message
                ));
        END;
    END LOOP;

    -- Step 4: Return the consolidated result
    RETURN jsonb_build_object(
        'success', v_failed_count = 0,
        'activated_count', v_activated_count,
        'failed_count', v_failed_count,
        'total_prorated_amount', v_total_prorated_amount,
        'details', to_jsonb(v_details)
    );
END;
$$;



DROP FUNCTION IF EXISTS "public"."activate_subscription"("p_tenant_id" "uuid", "p_plan_price_id" "uuid", "p_payment_id" "uuid");

CREATE OR REPLACE FUNCTION "public"."activate_subscription"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_plan_price_id" "uuid", "p_payment_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_plan_id UUID;
    v_tenant_country_id UUID;
    v_pcc_id UUID;
    v_billing_frequency_months INT;
    v_previous_end_date TIMESTAMPTZ;
    v_new_end_date TIMESTAMPTZ;
    v_new_start_date TIMESTAMPTZ;
BEGIN
    -- Steps 1-4: Get plan, country, and configuration info
    SELECT subscription_plan_id INTO v_plan_id
    FROM public.price_tariffs WHERE id = p_plan_price_id;
    IF v_plan_id IS NULL THEN RAISE EXCEPTION 'Plan not found for price_id: %', p_plan_price_id; END IF;

    SELECT country_id INTO v_tenant_country_id
    FROM public.tenants WHERE id = p_tenant_id;
    IF v_tenant_country_id IS NULL THEN RAISE EXCEPTION 'Country not found for tenant: %', p_tenant_id; END IF;

    SELECT id INTO v_pcc_id
    FROM public.plan_country_configurations WHERE plan_id = v_plan_id AND country_id = v_tenant_country_id;
    IF v_pcc_id IS NULL THEN RAISE EXCEPTION 'Plan configuration not found for plan % in country %', v_plan_id, v_tenant_country_id; END IF;

    SELECT billing_frequency_months INTO v_billing_frequency_months
    FROM public.subscription_plans WHERE id = v_plan_id;
    IF v_billing_frequency_months IS NULL THEN RAISE EXCEPTION 'Billing frequency not found for plan %', v_plan_id; END IF;

    -- 5. Find the end_date of the single ACTIVE subscription
    SELECT end_date INTO v_previous_end_date
    FROM public.tenant_subscriptions
    WHERE tenant_id = p_tenant_id AND platform_id = p_platform_id AND is_active = true
    LIMIT 1;

    -- 6. Calculate new dates. FOUND is a special variable that is true if the last SELECT INTO found a row.
    IF FOUND AND NOW() <= (v_previous_end_date + '5 days'::interval) THEN
        -- If an active subscription was found and it's still valid (or in grace period)
        v_new_start_date := v_previous_end_date;
        v_new_end_date := v_previous_end_date + (v_billing_frequency_months || ' months')::interval;
    ELSE
        -- If no active sub was found (FOUND is false) or it's long expired
        v_new_start_date := NOW();
        v_new_end_date := NOW() + (v_billing_frequency_months || ' months')::interval;
    END IF;

    -- 7. Deactivate all old subscriptions for the tenant
    UPDATE public.tenant_subscriptions
    SET is_active = false
    WHERE tenant_id = p_tenant_id AND platform_id = p_platform_id AND is_active = true;

    -- 8. Insert the new subscription record
    INSERT INTO public.tenant_subscriptions (
        tenant_id,
        plan_country_configuration_id,
        is_active,
        start_date,
        end_date,
        is_trial
    )
    VALUES (
        p_tenant_id,
        v_pcc_id,
        true,
        v_new_start_date,
        v_new_end_date,
        FALSE
    );

END;
$$;



DROP FUNCTION IF EXISTS "public"."assign_consent_to_appointment"("p_tenant_id" "uuid", "p_appointment_id" "uuid", "p_template_id" "uuid");

CREATE OR REPLACE FUNCTION "public"."assign_consent_to_appointment"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_appointment_id" "uuid", "p_template_id" "uuid") RETURNS "public"."signed_consents"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_client_id uuid;
    v_professional_id uuid;
    new_signed_consent public.signed_consents;
BEGIN
    -- Fetch client_id and professional_id from the appointments table
    SELECT
        a.client_id,
        a.user_id -- Assuming user_id in appointments is the professional_id
    INTO
        v_client_id,
        v_professional_id
    FROM
        public.appointments a
    WHERE
        a.id = p_appointment_id AND a.tenant_id = p_tenant_id AND platform_id = p_platform_id;

    -- Check if appointment exists and tenant matches
    IF v_client_id IS NULL THEN
        RAISE EXCEPTION 'Appointment with ID % not found for tenant %', p_appointment_id, p_tenant_id;
    END IF;

    -- Insert a new signed_consents record (initially unsigned)
    INSERT INTO public.signed_consents (
        appointment_id,
        client_id,
        professional_id,
        template_id,
        tenant_id,
        professional_observations, -- Initially null
        signed_content,            -- Initially null
        signed_at                  -- Initially null
    )
    VALUES (
        p_appointment_id,
        v_client_id,
        v_professional_id,
        p_template_id,
        p_tenant_id,
        NULL,
        NULL,
        NULL
    )
    RETURNING * INTO new_signed_consent;

    RETURN new_signed_consent;
END;
$$;



DROP FUNCTION IF EXISTS "public"."assign_equipment_to_user"("p_tenant_id" "uuid", "p_equipment_id" "uuid", "p_user_id" "uuid", "p_branch_id" "uuid", "p_assignment_date" "date");

CREATE OR REPLACE FUNCTION "public"."assign_equipment_to_user"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_equipment_id" "uuid", "p_user_id" "uuid", "p_branch_id" "uuid", "p_assignment_date" "date") RETURNS "uuid"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    new_assignment_id uuid;
BEGIN
    INSERT INTO equipment_assignments (tenant_id, platform_id, equipment_id, user_id, branch_id, assignment_date)
    VALUES (p_tenant_id, p_platform_id, p_equipment_id, p_user_id, p_branch_id, p_assignment_date)
    RETURNING id INTO new_assignment_id;
    RETURN new_assignment_id;
END;
$$;



DROP FUNCTION IF EXISTS "public"."calculate_batch_activation_proration"("p_tenant_id" "uuid", "p_branch_ids" "uuid"[]);

CREATE OR REPLACE FUNCTION "public"."calculate_batch_activation_proration"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_branch_ids" "uuid"[]) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_branch_id UUID;
    v_branch RECORD;
    v_subscription RECORD;
    v_subscription_status TEXT;
    v_days_in_cycle INT;
    v_days_remaining INT;
    v_daily_rate NUMERIC;
    v_prorated_amount NUMERIC;
    v_branch_price NUMERIC;
    
    v_total_prorated_amount NUMERIC := 0;
    v_details JSONB[] := ARRAY[]::JSONB[];
    v_error_message TEXT;
BEGIN
    -- Step 1: Verify the tenant has an active subscription
    SELECT status INTO v_subscription_status FROM public.get_tenant_subscription_status(p_tenant_id, p_platform_id);
    IF v_subscription_status != 'activo' THEN
        RAISE EXCEPTION 'Cannot calculate cost. Tenant subscription status is: %', v_subscription_status;
    END IF;

    -- Step 2: Get the latest subscription record
    SELECT * INTO v_subscription 
    FROM public.tenant_subscriptions 
    WHERE tenant_id = p_tenant_id AND platform_id = p_platform_id 
    ORDER BY end_date DESC NULLS FIRST 
    LIMIT 1;
    
    IF v_subscription IS NULL THEN 
        RAISE EXCEPTION 'No active subscription record found for the tenant.';
    END IF;

    -- Step 3: Loop through each branch ID to calculate cost
    FOREACH v_branch_id IN ARRAY p_branch_ids
    LOOP
        BEGIN
            -- Step 3a: Validate the branch
            SELECT * INTO v_branch FROM public.branches WHERE id = v_branch_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;
            IF v_branch IS NULL THEN RAISE EXCEPTION 'Branch not found or access denied'; END IF;
            IF v_branch.status <> 'pending_activation' THEN RAISE EXCEPTION 'Branch % is not pending activation', v_branch.name; END IF;

            -- Step 3b: Get the price for the plan from the new tariff tables
            WITH latest_tariff AS (
                SELECT id
                FROM public.price_tariffs
                WHERE subscription_plan_id = v_subscription.subscription_plan_id
                  AND effective_date <= NOW()
                ORDER BY effective_date DESC
                LIMIT 1
            )
            SELECT tap.extra_unit_price INTO v_branch_price
            FROM public.tariff_asset_prices AS tap
            JOIN public.plan_assets AS pa ON tap.asset_id = pa.id
            WHERE tap.tariff_id = (SELECT id FROM latest_tariff)
              AND pa.asset_key = 'suc_glam';

            IF v_branch_price IS NULL OR v_branch_price <= 0 THEN 
                RAISE EXCEPTION 'Could not find a valid price for branch %.', v_branch.name; 
            END IF;

            -- Step 3c: Proration Calculation
            IF v_subscription.end_date IS NULL THEN
                RAISE EXCEPTION 'The current subscription has no end date.';
            ELSE
                v_days_in_cycle := v_subscription.end_date::date - v_subscription.start_date::date;
                v_days_remaining := v_subscription.end_date::date - NOW()::date;
                v_prorated_amount := 0;
                IF v_days_remaining > 0 AND v_days_in_cycle > 0 THEN
                    v_daily_rate := v_branch_price / v_days_in_cycle;
                    v_prorated_amount := v_daily_rate * v_days_remaining;
                END IF;
            END IF;

            -- Step 3d: Log details for this branch
            v_total_prorated_amount := v_total_prorated_amount + round(v_prorated_amount, 2);
            v_details := array_append(v_details, jsonb_build_object(
                'branch_id', v_branch_id, 
                'branch_name', v_branch.name,
                'prorated_amount', round(v_prorated_amount, 2)
            ));

        EXCEPTION
            WHEN OTHERS THEN
                GET STACKED DIAGNOSTICS v_error_message = MESSAGE_TEXT;
                -- In a calculation function, it's better to raise the error to the client
                RAISE EXCEPTION 'Failed to calculate for branch %: %', v_branch_id, v_error_message;
        END;
    END LOOP;

    -- Step 4: Return the consolidated calculation
    RETURN jsonb_build_object(
        'total_prorated_amount', v_total_prorated_amount,
        'details', to_jsonb(v_details)
    );
END;
$$;



DROP FUNCTION IF EXISTS "public"."cancel_treatment_session"("p_session_id" "uuid", "p_tenant_id" "uuid");

CREATE OR REPLACE FUNCTION "public"."cancel_treatment_session"("p_session_id" "uuid", "p_tenant_id" "uuid", "p_platform_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    UPDATE public.client_treatment_sessions s
    SET status = 'Cancelada'
    FROM public.client_treatments ct -- JOIN
    WHERE 
        s.id = p_session_id 
        AND s.client_treatment_id = ct.id -- JOIN condition
        AND ct.tenant_id = p_tenant_id AND platform_id = p_platform_id   -- Security check on the parent table
        AND s.status = 'pending';
END;
$$;



DROP FUNCTION IF EXISTS "public"."check_asset_limit"("p_tenant_id" "uuid", "p_asset_key" "text");

CREATE OR REPLACE FUNCTION "public"."check_asset_limit"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_asset_key" "text") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_limit INT;
    v_current_count INT;
    v_plan_id UUID;
    v_asset_id UUID;
BEGIN
    -- Step 1: Find the tenant's active subscription plan
    SELECT active_plan_id INTO v_plan_id
    FROM public.tenant_subscriptions
    WHERE tenant_id = p_tenant_id AND platform_id = p_platform_id
    AND status = 'active'
    ORDER BY created_at DESC
    LIMIT 1;

    IF v_plan_id IS NULL THEN
        -- No active plan found, default to allowing the action
        RETURN TRUE;
    END IF;

    -- Step 2: Find the asset_id from the asset_key
    SELECT id INTO v_asset_id
    FROM public.plan_assets
    WHERE asset_key = p_asset_key
    -- This assumes asset_key is unique across platforms, or we need platform_id
    LIMIT 1;

    IF v_asset_id IS NULL THEN
        -- The asset type doesn't exist, so no limit is enforced
        RETURN TRUE;
    END IF;

    -- Step 3: Find the limit value for the plan and asset
    SELECT value::INT INTO v_limit
    FROM public.plan_asset_limits
    WHERE plan_id = v_plan_id AND asset_id = v_asset_id;

    IF v_limit IS NULL THEN
        -- No specific limit set for this asset in this plan, allow action
        RETURN TRUE;
    END IF;

    -- Step 4: Count the current number of resources based on the asset_key
    IF p_asset_key = 'max_branches' THEN
        SELECT COUNT(*)::INT INTO v_current_count
        FROM public.branches
        WHERE tenant_id = p_tenant_id AND platform_id = p_platform_id;
    -- Add other cases here in the future
    -- ELSIF p_asset_key = 'max_users' THEN
    --     SELECT COUNT(*)::INT INTO v_current_count ...
    ELSE
        -- If the asset key is unknown, we don't enforce a limit
        RETURN TRUE;
    END IF;

    -- Step 5: Compare current count with the limit
    RETURN v_current_count < v_limit;
END;
$$;



DROP FUNCTION IF EXISTS "public"."create_consent_template"("p_tenant_id" "uuid", "p_name" "text", "p_content" "text", "p_fields" "jsonb");

CREATE OR REPLACE FUNCTION "public"."create_consent_template"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_name" "text", "p_content" "text" DEFAULT NULL::"text", "p_fields" "jsonb" DEFAULT NULL::"jsonb") RETURNS "public"."informed_consent_templates"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    new_template public.informed_consent_templates;
BEGIN
    INSERT INTO public.informed_consent_templates (name, content, fields, tenant_id)
    VALUES (p_name, p_content, p_fields, p_tenant_id)
    RETURNING * INTO new_template;

    RETURN new_template;
END;
$$;



DROP FUNCTION IF EXISTS "public"."create_notification"("p_tenant_id" "uuid", "p_user_id" "uuid", "p_type" "public"."notification_type", "p_title" "text", "p_body" "text", "p_link_to" "text");

CREATE OR REPLACE FUNCTION "public"."create_notification"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_user_id" "uuid", "p_type" "public"."notification_type", "p_title" "text", "p_body" "text", "p_link_to" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    INSERT INTO public.notifications (tenant_id, platform_id, user_id, type, title, body, link_to)
    VALUES (p_tenant_id, p_platform_id, p_user_id, p_type, p_title, p_body, p_link_to);
END;
$$;



DROP FUNCTION IF EXISTS "public"."create_tenant_user"("p_email" "text", "p_role_id" "uuid", "p_tenant_id" "uuid", "p_branch_id" "uuid");

CREATE OR REPLACE FUNCTION "public"."create_tenant_user"("p_email" "text", "p_role_id" "uuid", "p_tenant_id" "uuid", "p_platform_id" "uuid", "p_branch_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_caller_role TEXT := (auth.jwt() -> 'app_metadata' ->> 'role');
    v_caller_tenant_id UUID := (auth.jwt() -> 'app_metadata' ->> 'tenant_id')::uuid;
    v_new_user_id UUID;
BEGIN
    -- Step 2a: Authorization Check
    IF v_caller_role NOT IN ('super_admin', 'tenant_super_admin', 'tenant_admin') THEN
        RAISE EXCEPTION 'Permission denied: You do not have rights to create users.';
    END IF;

    IF v_caller_role != 'super_admin' AND v_caller_tenant_id != p_tenant_id THEN
        RAISE EXCEPTION 'Permission denied: You can only create users within your own tenant.';
    END IF;

    -- Step 2b: Create the user in Supabase Auth via invitation
    SELECT auth.admin_create_user(p_email) INTO v_new_user_id;

    -- Step 2c: Assign role and tenancy using our helper function
    PERFORM public.set_user_assignment(
        p_target_user_id := v_new_user_id,
        p_tenant_id := p_tenant_id,
        p_platform_id := p_platform_id,
        p_role_id := p_role_id,
        p_branch_id := p_branch_id
    );

    -- Step 2d: Return a success message
    RETURN jsonb_build_object(
        'success', TRUE,
        'message', 'User invited successfully.',
        'user_id', v_new_user_id
    );

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$;



DROP FUNCTION IF EXISTS "public"."create_treatment"("p_tenant_id" "uuid", "p_name" "text", "p_description" "text", "p_type" "text", "p_upfront_price" numeric, "p_financed_price" numeric, "p_sessions" "jsonb");

CREATE OR REPLACE FUNCTION "public"."create_treatment"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_name" "text", "p_description" "text", "p_type" "text", "p_upfront_price" numeric, "p_financed_price" numeric, "p_sessions" "jsonb") RETURNS "public"."treatments"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    new_treatment public.treatments;
    session_data jsonb;
    new_session_id uuid;
    item_data jsonb;
BEGIN
    INSERT INTO public.treatments (tenant_id, platform_id, name, description, type, upfront_price, financed_price)
    VALUES (p_tenant_id, p_platform_id, p_name, p_description, p_type, p_upfront_price, p_financed_price)
    RETURNING * INTO new_treatment;

    IF p_sessions IS NOT NULL AND jsonb_array_length(p_sessions) > 0 THEN
        FOR session_data IN SELECT * FROM jsonb_array_elements(p_sessions) LOOP
            INSERT INTO public.treatment_sessions (
                treatment_id,
                session_number,
                name,
                description,
                payment_percentage,
                fixed_payment_amount
            )
            VALUES (
                new_treatment.id,
                (session_data->>'session_number')::int,
                session_data->>'name',
                session_data->>'description',
                (NULLIF(session_data->>'payment_percentage', 'null'))::numeric,
                (NULLIF(session_data->>'fixed_payment_amount', 'null'))::numeric
            )
            RETURNING id INTO new_session_id;

            IF session_data->'items' IS NOT NULL AND jsonb_array_length(session_data->'items') > 0 THEN
                FOR item_data IN SELECT * FROM jsonb_array_elements(session_data->'items') LOOP
                    INSERT INTO public.treatment_session_items (
                        session_id,
                        product_id,
                        service_id,
                        quantity,
                        notes
                    )
                    VALUES (
                        new_session_id,
                        (item_data->>'product_id')::uuid,
                        (item_data->>'service_id')::uuid,
                        (item_data->>'quantity')::int,
                        item_data->>'notes'
                    );
                END LOOP;
            END IF;
        END LOOP;
    END IF;

    RETURN new_treatment;
END;
$$;



DROP FUNCTION IF EXISTS "public"."delete_equipment"("p_tenant_id" "uuid", "p_equipment_id" "uuid");

CREATE OR REPLACE FUNCTION "public"."delete_equipment"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_equipment_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    DELETE FROM equipment WHERE id = p_equipment_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;
END;
$$;



DROP FUNCTION IF EXISTS "public"."delete_tenant_cascade"("target_tenant_id" "uuid");

CREATE OR REPLACE FUNCTION "public"."delete_tenant_cascade"("target_tenant_id" "uuid", "p_platform_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RAISE LOG 'Iniciando borrado en cascada (v4) para el tenant: %', target_tenant_id;

    -- Nivel 1: Datos de eventos y logs (audit_logs y metrics ya no existen en este esquema)
    
    RAISE LOG 'Borrando appointment_evidence...';
    DELETE FROM appointment_evidence WHERE tenant_id = target_tenant_id AND platform_id = p_platform_id;
    RAISE LOG 'Borrando appointment_extra_services...';
    DELETE FROM appointment_extra_services WHERE tenant_id = target_tenant_id AND platform_id = p_platform_id;
    RAISE LOG 'Borrando appointment_products...';
    DELETE FROM appointment_products WHERE tenant_id = target_tenant_id AND platform_id = p_platform_id;
    RAISE LOG 'Borrando appointment_sessions...';
    DELETE FROM appointment_sessions WHERE tenant_id = target_tenant_id AND platform_id = p_platform_id;
    RAISE LOG 'Borrando attention_products...';
    DELETE FROM attention_products WHERE tenant_id = target_tenant_id AND platform_id = p_platform_id;
    RAISE LOG 'Borrando attention_service_products...';
    DELETE FROM attention_service_products WHERE tenant_id = target_tenant_id AND platform_id = p_platform_id;
    RAISE LOG 'Borrando attention_services...';
    DELETE FROM attention_services WHERE tenant_id = target_tenant_id AND platform_id = p_platform_id;
    RAISE LOG 'Borrando extra_service_sessions...';
    DELETE FROM extra_service_sessions WHERE tenant_id = target_tenant_id AND platform_id = p_platform_id;
    RAISE LOG 'Borrando service_evidence...';
    DELETE FROM service_evidence WHERE tenant_id = target_tenant_id AND platform_id = p_platform_id;
    RAISE LOG 'Borrando service_sessions...';
    DELETE FROM service_sessions WHERE tenant_id = target_tenant_id AND platform_id = p_platform_id;
    RAISE LOG 'Borrando product_stylist_commissions...';
    DELETE FROM product_stylist_commissions WHERE tenant_id = target_tenant_id AND platform_id = p_platform_id;
    RAISE LOG 'Borrando service_stylist_commissions...';
    DELETE FROM service_stylist_commissions WHERE tenant_id = target_tenant_id AND platform_id = p_platform_id;
    RAISE LOG 'Borrando purchase_items...';
    DELETE FROM purchase_items WHERE tenant_id = target_tenant_id AND platform_id = p_platform_id;
    RAISE LOG 'Borrando stylist_time_off...';
    DELETE FROM stylist_time_off WHERE tenant_id = target_tenant_id AND platform_id = p_platform_id;
    RAISE LOG 'Borrando user_permissions...';
    DELETE FROM user_permissions WHERE tenant_id = target_tenant_id AND platform_id = p_platform_id;
    RAISE LOG 'Borrando menu_permissions...';
    DELETE FROM menu_permissions WHERE tenant_id = target_tenant_id AND platform_id = p_platform_id;

    -- Nivel 2: Entidades transaccionales principales
    RAISE LOG 'Borrando appointments...';
    DELETE FROM appointments WHERE tenant_id = target_tenant_id AND platform_id = p_platform_id;
    RAISE LOG 'Borrando attentions...';
    DELETE FROM attentions WHERE tenant_id = target_tenant_id AND platform_id = p_platform_id;
    RAISE LOG 'Borrando purchases...';
    DELETE FROM purchases WHERE tenant_id = target_tenant_id AND platform_id = p_platform_id;
    RAISE LOG 'Borrando stylist_schedules...';
    DELETE FROM stylist_schedules WHERE tenant_id = target_tenant_id AND platform_id = p_platform_id;

    -- Nivel 3: Usuarios y sus datos asociados
    RAISE LOG 'Borrando users...';
    DELETE FROM users WHERE tenant_id = target_tenant_id AND platform_id = p_platform_id;
    RAISE LOG 'Borrando stylists...';
    DELETE FROM stylists WHERE tenant_id = target_tenant_id AND platform_id = p_platform_id;
    RAISE LOG 'Borrando clients...';
    DELETE FROM clients WHERE tenant_id = target_tenant_id AND platform_id = p_platform_id;

    -- Nivel 4: Catálogos y datos de negocio base
    RAISE LOG 'Borrando supplier_products...';
    DELETE FROM supplier_products WHERE tenant_id = target_tenant_id AND platform_id = p_platform_id;
    RAISE LOG 'Borrando suppliers...';
    DELETE FROM suppliers WHERE tenant_id = target_tenant_id AND platform_id = p_platform_id;
    RAISE LOG 'Borrando products...';
    DELETE FROM products WHERE tenant_id = target_tenant_id AND platform_id = p_platform_id;
    RAISE LOG 'Borrando services...';
    DELETE FROM services WHERE tenant_id = target_tenant_id AND platform_id = p_platform_id;
    RAISE LOG 'Borrando service_categories...';
    DELETE FROM service_categories WHERE tenant_id = target_tenant_id AND platform_id = p_platform_id;
    RAISE LOG 'Borrando brands...';
    DELETE FROM brands WHERE tenant_id = target_tenant_id AND platform_id = p_platform_id;
    RAISE LOG 'Borrando schedule_templates...';
    DELETE FROM schedule_templates WHERE tenant_id = target_tenant_id AND platform_id = p_platform_id;

    -- Nivel 5: Configuración del Tenant
    RAISE LOG 'Borrando branches...';
    DELETE FROM branches WHERE tenant_id = target_tenant_id AND platform_id = p_platform_id;
    RAISE LOG 'Borrando translations...';
    DELETE FROM translations WHERE tenant_id = target_tenant_id AND platform_id = p_platform_id;
    RAISE LOG 'Borrando tenant_subscriptions...';
    DELETE FROM tenant_subscriptions WHERE tenant_id = target_tenant_id AND platform_id = p_platform_id;

    -- Nivel Final: El tenant mismo
    RAISE LOG 'Borrando el tenant principal...';
    DELETE FROM tenants WHERE id = target_tenant_id;

    RAISE LOG 'Borrado en cascada (v4) completado para el tenant: %', target_tenant_id;
END;
$$;



DROP FUNCTION IF EXISTS "public"."delete_tenant_integration"("p_tenant_id" "uuid", "p_provider" "text", "p_requesting_user_role" "text");

CREATE OR REPLACE FUNCTION "public"."delete_tenant_integration"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_provider" "text", "p_requesting_user_role" "text") RETURNS json
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    integration_record RECORD;
    rows_deleted INT;
BEGIN
    -- Security Check
    IF p_requesting_user_role != 'super_admin' THEN
        RAISE EXCEPTION 'Access denied. Super admin role required.';
    END IF;

    -- Get the integration record for the SPECIFIC tenant
    SELECT * INTO integration_record
    FROM public.tenant_integrations
    WHERE
        tenant_id = p_tenant_id AND platform_id = p_platform_id -- <-- THE CRITICAL FIX
    AND 
        (provider = p_provider OR (p_provider = 'google' AND provider = 'google_drive'));

    -- If no record is found for this tenant, exit gracefully
    IF integration_record IS NULL THEN
        RETURN json_build_object('success', true, 'message', 'No integration found for this tenant to delete.');
    END IF;

    -- (The token revocation logic can be added back here later if needed)

    -- Delete the local integration record using its specific ID
    WITH deleted_rows AS (
        DELETE FROM public.tenant_integrations
        WHERE id = integration_record.id
        RETURNING 1
    )
    SELECT count(*) INTO rows_deleted FROM deleted_rows;

    -- Return a success message
    RETURN json_build_object('success', TRUE, 'message', 'Integración eliminada correctamente.', 'rows_deleted', rows_deleted);

EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION 'An unexpected error occurred during integration deletion: %', SQLERRM;
END;
$$;



DROP FUNCTION IF EXISTS "public"."delete_treatment"("p_treatment_id" "uuid", "p_tenant_id" "uuid");

CREATE OR REPLACE FUNCTION "public"."delete_treatment"("p_treatment_id" "uuid", "p_tenant_id" "uuid", "p_platform_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    DELETE FROM public.treatments
    WHERE id = p_treatment_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Treatment not found or not owned by tenant.';
    END IF;
END;
$$;



DROP FUNCTION IF EXISTS "public"."get_branch_aggregate_rating"("p_branch_id" "uuid", "p_tenant_id" "uuid");

CREATE OR REPLACE FUNCTION "public"."get_branch_aggregate_rating"("p_branch_id" "uuid", "p_tenant_id" "uuid", "p_platform_id" "uuid") RETURNS TABLE("average_rating" numeric, "review_count" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
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
        AND ssr.tenant_id = p_tenant_id AND platform_id = p_platform_id;
END;
$$;



DROP FUNCTION IF EXISTS "public"."get_branch_commission_matrix"("branch_id_param" "uuid", "tenant_id_param" "uuid");

CREATE OR REPLACE FUNCTION "public"."get_branch_commission_matrix"("branch_id_param" "uuid", "tenant_id_param" "uuid", "p_platform_id" "uuid") RETURNS TABLE("item_id" "uuid", "item_name" "text", "item_type" "text", "users" json)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  RETURN QUERY
  WITH branch_products AS (
    SELECT bp.product_id as id, p.name, 'product' as type
    FROM public.branch_products bp
    JOIN public.products p ON bp.product_id = p.id
    WHERE bp.branch_id = branch_id_param AND bp.tenant_id = tenant_id_param AND platform_id = p_platform_id
  ),
  branch_services AS (
    SELECT bs.service_id as id, s.name, 'service' as type
    FROM public.branch_services bs
    JOIN public.services s ON bs.service_id = s.id
    WHERE bs.branch_id = branch_id_param AND bs.tenant_id = tenant_id_param AND platform_id = p_platform_id
  ),
  all_items_in_branch AS (
    SELECT id, name, type FROM branch_products
    UNION ALL
    SELECT id, name, type FROM branch_services
  ),
  relevant_users AS (
    SELECT DISTINCT ua.user_id, (u.raw_user_meta_data->>'first_name') || ' ' || (u.raw_user_meta_data->>'last_name') as user_name
    FROM public.user_assignments ua
    JOIN auth.users u ON ua.user_id = u.id
    WHERE ua.tenant_id = tenant_id_param AND platform_id = p_platform_id AND ua.status = 'active'
  ),
  commission_matrix AS (
    SELECT
      ai.id as item_id,
      ai.name as item_name,
      ai.type as item_type,
      ru.user_id,
      ru.user_name
    FROM all_items_in_branch ai
    CROSS JOIN relevant_users ru
  )
  SELECT
    cm.item_id,
    cm.item_name,
    cm.item_type,
    json_agg(
      json_build_object(
        'user_id', cm.user_id,
        'user_name', cm.user_name,
        'commission_rate',
          CASE
            WHEN cm.item_type = 'product' THEN pc.commission_rate
            WHEN cm.item_type = 'service' THEN sc.commission_rate
            ELSE NULL
          END,
        'can_perform',
          CASE
            WHEN cm.item_type = 'service' THEN sc.can_perform
            ELSE NULL
          END,
        'commission_id',
          CASE
            WHEN cm.item_type = 'product' THEN pc.id
            WHEN cm.item_type = 'service' THEN sc.id
            ELSE NULL
          END
      )
    )::json as users
  FROM commission_matrix cm
  LEFT JOIN public.product_user_commissions pc
    ON cm.item_id = pc.product_id
    AND cm.user_id = pc.user_id
    AND branch_id_param = pc.branch_id
  LEFT JOIN public.service_user_commissions sc
    ON cm.item_id = sc.service_id
    AND cm.user_id = sc.user_id
    AND branch_id_param = sc.branch_id
  GROUP BY cm.item_id, cm.item_name, cm.item_type;
END;
$$;



DROP FUNCTION IF EXISTS "public"."get_branches_for_microsite"("p_tenant_id" "uuid");

CREATE OR REPLACE FUNCTION "public"."get_branches_for_microsite"("p_tenant_id" "uuid", "p_platform_id" "uuid") RETURNS json
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_branches json;
BEGIN
    -- Find all active branches for that tenant, including their primary photo and social networks
    SELECT json_agg(
        json_build_object(
            'id', b.id,
            'name', b.name,
            'address', b.address,
            'description', b.description,
            'contact_phone', b.contact_phone,
            'whatsapp_phone', b.whatsapp_phone,
            'latitude', b.latitude,
            'longitude', b.longitude,
            'primary_photo_gdrive_id', (
                SELECT bp.google_drive_file_id
                FROM public.branch_photos bp
                WHERE bp.branch_id = b.id AND bp.is_primary = true
                LIMIT 1
            ),
            'social_networks', (
                SELECT COALESCE(json_agg(
                    json_build_object('network', bsn.network, 'url', bsn.url)
                ), '[]'::json)
                FROM public.branch_social_networks bsn
                WHERE bsn.branch_id = b.id
            )
        )
    )
    INTO v_branches
    FROM public.branches b
    WHERE b.tenant_id = p_tenant_id AND platform_id = p_platform_id AND b.status = 'active' AND b.is_visible_on_microsite = true;

    RETURN COALESCE(v_branches, '[]'::json);
END;
$$;



DROP FUNCTION IF EXISTS "public"."get_consent_template"("p_tenant_id" "uuid", "p_id" "uuid");

CREATE OR REPLACE FUNCTION "public"."get_consent_template"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_id" "uuid") RETURNS SETOF "public"."informed_consent_templates"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    RETURN QUERY
    SELECT *
    FROM public.informed_consent_templates
    WHERE id = p_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;
END;
$$;



DROP FUNCTION IF EXISTS "public"."get_detailed_combos_for_branch"("p_tenant_id" "uuid", "p_branch_id" "uuid");

CREATE OR REPLACE FUNCTION "public"."get_detailed_combos_for_branch"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_branch_id" "uuid") RETURNS TABLE("id" "uuid", "name" "text", "description" "text", "sku" "text", "is_active_in_branch" boolean, "items" "jsonb")
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        c.id,
        c.name,
        c.description,
        c.sku,
        bc.is_active AS is_active_in_branch,
        COALESCE(
            (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'item_id', ci.id,
                        'product_id', ci.product_id,
                        'service_id', ci.service_id,
                        'name', COALESCE(p.name, s.name),
                        'quantity', ci.quantity,
                        'base_price', ci.price,
                        'override_price', bcip.price,
                        'final_price', COALESCE(bcip.price, ci.price),
                        'duration_minutes', COALESCE(s.duration_minutes, 0) -- THE FIX
                    )
                )
                FROM public.combo_items ci
                LEFT JOIN public.products p ON p.id = ci.product_id
                LEFT JOIN public.services s ON s.id = ci.service_id
                LEFT JOIN public.branch_combo_item_prices bcip ON bcip.combo_id = ci.combo_id
                    AND bcip.branch_id = p_branch_id
                    AND (bcip.product_id = ci.product_id OR bcip.service_id = ci.service_id)
                WHERE ci.combo_id = c.id
            ),
            '[]'::jsonb
        ) AS items
    FROM public.combos c
    JOIN public.branch_combos bc ON bc.combo_id = c.id
    WHERE
        c.tenant_id = p_tenant_id AND platform_id = p_platform_id AND bc.branch_id = p_branch_id
    ORDER BY c.name ASC;
END;
$$;



DROP FUNCTION IF EXISTS "public"."get_next_document_number"("p_tenant_id" "uuid", "p_document_type" "text", "p_branch_id" "uuid", "p_context_data" "jsonb");

CREATE OR REPLACE FUNCTION "public"."get_next_document_number"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_document_type" "text", "p_branch_id" "uuid" DEFAULT NULL::"uuid", "p_context_data" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    sequence_rec RECORD;
    branch_rec RECORD;
    formatted_number text;
    next_number integer;
    current_ts timestamptz := now(); -- Get current timestamp once
BEGIN
    -- Find the appropriate sequence and lock the row for update
    SELECT *
    INTO sequence_rec
    FROM public.document_sequences
    WHERE tenant_id = p_tenant_id AND platform_id = p_platform_id
      AND document_type = p_document_type
      AND (branch_id = p_branch_id OR branch_id IS NULL)
      AND is_active = true
    ORDER BY branch_id DESC NULLS LAST
    LIMIT 1
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No active document sequence found for document type %', p_document_type;
    END IF;

    -- Get the number for the current document
    next_number := sequence_rec.current_number;

    -- Increment the number for the next call
    UPDATE public.document_sequences
    SET current_number = current_number + 1
    WHERE id = sequence_rec.id;

    -- Start with the format template
    formatted_number := COALESCE(sequence_rec.format_template, '{prefix}{sequence}');

    -- Replace date placeholders
    formatted_number := replace(formatted_number, '{YYYY}', to_char(current_ts, 'YYYY'));
    formatted_number := replace(formatted_number, '{YY}', to_char(current_ts, 'YY'));
    formatted_number := replace(formatted_number, '{MM}', to_char(current_ts, 'MM'));
    formatted_number := replace(formatted_number, '{DD}', to_char(current_ts, 'DD'));

    -- Replace other placeholders
    formatted_number := replace(formatted_number, '{prefix}', COALESCE(sequence_rec.prefix, ''));
    formatted_number := replace(formatted_number, '{sequence}', LPAD(next_number::text, sequence_rec.padding, '0'));

    IF p_branch_id IS NOT NULL THEN
        SELECT code INTO branch_rec FROM public.branches WHERE id = p_branch_id;
        IF FOUND THEN
            formatted_number := replace(formatted_number, '{branch_code}', COALESCE(branch_rec.code, ''));
        END IF;
    END IF;

    IF p_context_data ? 'direction' THEN
        formatted_number := replace(formatted_number, '{direction}', p_context_data->>'direction');
    END IF;

    RETURN formatted_number;
END;
$$;



DROP FUNCTION IF EXISTS "public"."get_signed_consents_for_appointment"("p_tenant_id" "uuid", "p_appointment_id" "uuid");

CREATE OR REPLACE FUNCTION "public"."get_signed_consents_for_appointment"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_appointment_id" "uuid") RETURNS TABLE("id" "uuid", "appointment_id" "uuid", "client_id" "uuid", "professional_id" "uuid", "template_id" "uuid", "template_name" "text", "professional_observations" "text", "signed_content" "text", "signed_at" timestamp with time zone, "created_at" timestamp with time zone, "updated_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        sc.id,
        sc.appointment_id,
        sc.client_id,
        sc.professional_id,
        sc.template_id,
        ict.name AS template_name,
        sc.professional_observations,
        sc.signed_content,
        sc.signed_at,
        sc.created_at,
        sc.updated_at
    FROM
        public.signed_consents sc
    JOIN
        public.informed_consent_templates ict ON sc.template_id = ict.id
    WHERE
        sc.tenant_id = p_tenant_id AND platform_id = p_platform_id AND sc.appointment_id = p_appointment_id
    ORDER BY
        sc.created_at;
END;
$$;



DROP FUNCTION IF EXISTS "public"."get_stock_snapshot"("p_tenant_id" "uuid", "p_branch_id" "uuid", "p_report_date" "date");

CREATE OR REPLACE FUNCTION "public"."get_stock_snapshot"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_branch_id" "uuid", "p_report_date" "date") RETURNS TABLE("product_id" "uuid", "product_name" "text", "product_sku" "text", "stock_at_date" numeric, "cost_at_date" numeric, "last_movement_date" timestamp with time zone)
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY
    WITH ranked_movements AS (
        SELECT
            pm.product_id,
            pm.stock_after_movement,
            pm.cost_after_movement,
            pm.movement_date,
            ROW_NUMBER() OVER(PARTITION BY pm.product_id ORDER BY pm.movement_date DESC, pm.id DESC) as rn
        FROM public.product_movements pm
        WHERE pm.tenant_id = p_tenant_id AND platform_id = p_platform_id
          AND pm.branch_id = p_branch_id
          AND pm.movement_date <= p_report_date::timestamptz + interval '1 day' - interval '1 second' -- End of the selected day
    )
    SELECT
        p.id,
        p.name,
        p.sku,
        rm.stock_after_movement,
        rm.cost_after_movement,
        rm.movement_date
    FROM ranked_movements rm
    JOIN public.products p ON rm.product_id = p.id
    WHERE rm.rn = 1;
END;
$$;



DROP FUNCTION IF EXISTS "public"."get_subscription_plans_for_tenant"("p_tenant_id" "uuid");

CREATE OR REPLACE FUNCTION "public"."get_subscription_plans_for_tenant"("p_tenant_id" "uuid", "p_platform_id" "uuid") RETURNS TABLE("plan_id" "uuid", "plan_name" "text", "plan_description" "text", "plan_features" "text"[], "billing_frequency_months" integer, "price_id" "uuid", "calculated_price" numeric, "calculated_extra_branch_price" numeric, "calculated_promotional_price" numeric, "currency_code" "text", "currency_symbol" "text", "base_price" numeric, "active_branches_count" integer)
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_country_id UUID;
    v_platform_id UUID;
    v_active_branch_assets_count INT;
    v_current_subscription_id UUID;
BEGIN
    SELECT country_id, platform_id INTO v_country_id, v_platform_id FROM public.tenants WHERE id = p_tenant_id;
    
    IF v_country_id IS NULL THEN 
        RAISE EXCEPTION 'País no encontrado para el tenant: %', p_tenant_id; 
    END IF;
    IF v_platform_id IS NULL THEN 
        RAISE EXCEPTION 'Plataforma no encontrada para el tenant: %', p_tenant_id; 
    END IF;

    SELECT id INTO v_current_subscription_id
    FROM public.tenant_subscriptions
    WHERE tenant_id = p_tenant_id AND platform_id = p_platform_id
    ORDER BY end_date DESC NULLS FIRST
    LIMIT 1;

    IF v_current_subscription_id IS NOT NULL THEN
        SELECT count(*)::INT INTO v_active_branch_assets_count
        FROM public.subscription_assets
        WHERE tenant_subscription_id = v_current_subscription_id
          AND asset_type = 'branch'
          AND status = 'active';
    ELSE
        v_active_branch_assets_count := 0;
    END IF;

    RETURN QUERY
    SELECT
        gcp.plan_id,
        gcp.plan_name,
        gcp.plan_description,
        gcp.plan_features,
        gcp.billing_frequency_months,
        gcp.price_id,
        (gcp.calculated_price + (v_active_branch_assets_count * gcp.calculated_extra_branch_price)) AS calculated_price,
        gcp.calculated_extra_branch_price,
        gcp.calculated_promotional_price,
        gcp.currency_code,
        gcp.currency_symbol,
        gcp.calculated_price AS base_price,
        v_active_branch_assets_count AS active_branches_count
    FROM
        public.get_calculated_plan_prices(v_platform_id) gcp
    WHERE
        gcp.country_id = v_country_id;
END;
$$;



DROP FUNCTION IF EXISTS "public"."get_tenant_activity_summary"("p_tenant_id" "uuid");

CREATE OR REPLACE FUNCTION "public"."get_tenant_activity_summary"("p_tenant_id" "uuid", "p_platform_id" "uuid") RETURNS TABLE("tenant_id" "uuid", "tenant_name" "text", "total_users" bigint, "total_clients" bigint, "total_appointments" bigint, "total_services" bigint, "total_products" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    IF NOT public.is_super_admin() THEN
        RAISE EXCEPTION 'Acceso denegado. Solo los superadministradores pueden ver el resumen de actividad de los tenants.';
    END IF;

    RETURN QUERY
    SELECT
        t.id AS tenant_id,
        t.name AS tenant_name,
        (SELECT COUNT(DISTINCT u.id) FROM auth.users u JOIN public.user_assignments ua ON u.id = ua.user_id WHERE ua.tenant_id = t.id) AS total_users,
        (SELECT COUNT(*) FROM public.clients c WHERE c.tenant_id = t.id) AS total_clients,
        (SELECT COUNT(*) FROM public.attentions a WHERE a.tenant_id = t.id) AS total_appointments,
        (SELECT COUNT(*) FROM public.services s WHERE s.tenant_id = t.id) AS total_services,
        (SELECT COUNT(*) FROM public.products p WHERE p.tenant_id = t.id) AS total_products
    FROM
        public.tenants t
    WHERE t.id = p_tenant_id;
END;
$$;



DROP FUNCTION IF EXISTS "public"."get_tenant_integrations"("p_tenant_id" "uuid", "p_environment" "text");

CREATE OR REPLACE FUNCTION "public"."get_tenant_integrations"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_environment" "text" DEFAULT NULL::"text") RETURNS TABLE("id" "uuid", "tenant_id" "uuid", "provider" "text", "access_token" "text", "account_email" "text", "created_at" timestamp with time zone, "updated_at" timestamp with time zone, "expires_at" timestamp with time zone, "encrypted_credentials" "text", "nonce" "text", "environment" "text", "is_active" boolean)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    AS $$
DECLARE
    v_caller_role TEXT := (auth.jwt() -> 'app_metadata' ->> 'role');
    v_caller_tenant_id UUID := (auth.jwt() -> 'app_metadata' ->> 'tenant_id')::uuid;
BEGIN
    -- Security check: Allow access if the caller is a super_admin
    -- OR if the caller's tenant_id matches the requested tenant_id.
    IF v_caller_role != 'super_admin' AND v_caller_tenant_id != p_tenant_id THEN
        RAISE EXCEPTION 'Access denied. You do not have permission to view integrations for this tenant.';
    END IF;

    -- The main query remains the same, just the authorization logic changes.
    RETURN QUERY
    SELECT
        ti.id,
        ti.tenant_id,
        ti.provider,
        ti.access_token,
        ti.account_email,
        ti.created_at,
        ti.updated_at,
        ti.expires_at,
        ti.encrypted_credentials,
        ti.nonce,
        ti.environment,
        ti.is_active
    FROM
        public.tenant_integrations ti
    WHERE
        ti.tenant_id = p_tenant_id AND platform_id = p_platform_id
        AND (p_environment IS NULL OR ti.environment = p_environment);
END;
$$;



DROP FUNCTION IF EXISTS "public"."get_tenant_settings_data"("tenant_id_param" "uuid");

CREATE OR REPLACE FUNCTION "public"."get_tenant_settings_data"("tenant_id_param" "uuid", "p_platform_id" "uuid") RETURNS json
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  RETURN json_build_object(
    'tenant', (
      SELECT json_build_object(
        'id', t.id,
        'name', t.name,
        'logo_url', t.logo_url,
        'slug', t.slug,
        'description', t.description, -- Added
        'country_id', t.country_id,
        'default_language_code', t.default_language_code,
        'default_currency_id', t.default_currency_id,
        'default_timezone', t.default_timezone,
        'contact_phone', t.contact_phone,
        'whatsapp_phone', t.whatsapp_phone,
        'commercial_email', t.commercial_email,
        'legal_name', t.legal_name,
        'tax_id', t.tax_id,
        'billing_address', t.billing_address,
        'einvoicing_email', t.einvoicing_email,
        'physical_address_line1', t.physical_address_line1,
        'physical_address_line2', t.physical_address_line2,
        'physical_city', t.physical_city,
        'physical_state', t.physical_state,
        'physical_postal_code', t.physical_postal_code,
        'website', t.website,
        'latitude', t.latitude,
        'longitude', t.longitude
      )
      FROM tenants t
      WHERE t.id = tenant_id_param
    ),
    'countries', (
      SELECT json_agg(
        json_build_object(
          'id', c.id,
          'name', c.name,
          'iso_code', c.iso_code,
          'is_active', c.is_active,
          'default_localization_id', c.default_localization_id,
          'default_currency_id', c.default_currency_id,
          'timezones', (
            SELECT json_agg(tz.name)
            FROM public.country_timezones ct
            JOIN public.timezones tz ON ct.timezone_id = tz.id
            WHERE ct.country_id = c.id
          )
        )
      )
      FROM countries c
      WHERE c.is_active = true
    ),
    'languages', (
      SELECT json_agg(
        json_build_object(
          'id', l.id,
          'name', l.name,
          'iso_code', l.iso_code
        )
      )
      FROM languages l
      WHERE l.is_active = true
    ),
    'currencies', (
      SELECT json_agg(
        json_build_object(
          'id', curr.id,
          'name', curr.name,
          'symbol', curr.symbol,
          'code', curr.code,
          'decimal_places', curr.decimal_places,
          'symbol_position', curr.symbol_position,
          'decimal_separator', curr.decimal_separator,
          'thousands_separator', curr.thousands_separator
        )
      )
      FROM currencies curr
      WHERE curr.is_active = true
    )
  );
END;
$$;



DROP FUNCTION IF EXISTS "public"."get_tenant_storage_usage_by_table"("p_tenant_id" "uuid");

CREATE OR REPLACE FUNCTION "public"."get_tenant_storage_usage_by_table"("p_tenant_id" "uuid", "p_platform_id" "uuid") RETURNS TABLE("category" "text", "table_name" "text", "size" bigint, "branch_id" "uuid")
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  main_branch_id UUID;
BEGIN
  -- Find the main branch for the tenant
  SELECT id INTO main_branch_id FROM public.branches WHERE tenant_id = p_tenant_id AND platform_id = p_platform_id AND is_main_branch = TRUE LIMIT 1;
  
  RETURN QUERY
    WITH storage_data AS (
      -- Tenant-wide assets attributed to the main branch
      SELECT 
        'Productos y Servicios' AS category, 'Productos' AS table_name, coalesce(sum(file_size), 0)::BIGINT AS "size", main_branch_id AS branch_id
      FROM product_images WHERE tenant_id = p_tenant_id AND platform_id = p_platform_id
      UNION ALL
      SELECT 
        'Productos y Servicios' AS category, 'Servicios' AS table_name, coalesce(sum(file_size), 0)::BIGINT AS "size", main_branch_id AS branch_id
      FROM service_images WHERE tenant_id = p_tenant_id AND platform_id = p_platform_id
      UNION ALL
      SELECT 
        'Productos y Servicios' AS category, 'Combos' AS table_name, coalesce(sum(file_size), 0)::BIGINT AS "size", main_branch_id AS branch_id
      FROM combo_images WHERE tenant_id = p_tenant_id AND platform_id = p_platform_id
      UNION ALL
      SELECT 
        'Productos y Servicios' AS category, 'Tratamientos' AS table_name, coalesce(sum(file_size), 0)::BIGINT AS "size", main_branch_id AS branch_id
      FROM treatment_images WHERE tenant_id = p_tenant_id AND platform_id = p_platform_id
      
      -- Branch-specific assets
      UNION ALL
      SELECT 
        'Otros' AS category, 'Sucursales' AS table_name, coalesce(sum(file_size), 0)::BIGINT AS "size", bp.branch_id
      FROM branch_photos bp WHERE bp.tenant_id = p_tenant_id AND platform_id = p_platform_id GROUP BY bp.branch_id
      UNION ALL
      SELECT 
        'Evidencias' AS category, 'Evidencias de Servicios' AS table_name, coalesce(sum(file_size), 0)::BIGINT AS "size", ase.branch_id
      FROM attention_service_evidences ase WHERE ase.tenant_id = p_tenant_id AND platform_id = p_platform_id GROUP BY ase.branch_id
      UNION ALL
      SELECT 
        'Evidencias' AS category, 'Evidencias de Pagos' AS table_name, coalesce(sum(file_size), 0)::BIGINT AS "size", ape.branch_id
      FROM attention_payment_evidences ape WHERE ape.tenant_id = p_tenant_id AND platform_id = p_platform_id GROUP BY ape.branch_id
      UNION ALL
      SELECT 
        'Firmas' AS category, 'Consentimientos' AS table_name, coalesce(sum(cs.file_size), 0)::BIGINT AS "size", cs.branch_id
      FROM consent_signatures cs WHERE cs.tenant_id = p_tenant_id AND platform_id = p_platform_id GROUP BY cs.branch_id
      UNION ALL
      SELECT 
        'Firmas' AS category, 'Comisiones' AS table_name, coalesce(sum(file_size), 0)::BIGINT AS "size", cpe.branch_id
      FROM commission_payment_evidences cpe WHERE cpe.tenant_id = p_tenant_id AND platform_id = p_platform_id GROUP BY cpe.branch_id
    )
    SELECT sd.category, sd.table_name, sd."size", sd.branch_id FROM storage_data AS sd WHERE sd."size" > 0;
END;
$$;



DROP FUNCTION IF EXISTS "public"."get_tenant_subscription_status"("p_tenant_id" "uuid");

CREATE OR REPLACE FUNCTION "public"."get_tenant_subscription_status"("p_tenant_id" "uuid", "p_platform_id" "uuid") RETURNS TABLE("status" "text", "end_date" timestamp with time zone, "plan_name" "text")
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_current_active_subscription RECORD;
    v_latest_subscription RECORD;
    v_plan_name TEXT;
    v_is_system_owner BOOLEAN;
BEGIN
    -- Check if the tenant is the system owner
    SELECT is_system_owner INTO v_is_system_owner
    FROM public.tenants
    WHERE id = p_tenant_id;

    IF v_is_system_owner IS TRUE THEN
        RETURN QUERY SELECT 'activo'::TEXT, NULL::TIMESTAMPTZ, 'System Owner'::TEXT;
        RETURN;
    END IF;

    -- 1. Try to find a currently active subscription
    SELECT ts.* INTO v_current_active_subscription
    FROM public.tenant_subscriptions ts
    WHERE ts.tenant_id = p_tenant_id AND platform_id = p_platform_id
      AND NOW() >= ts.start_date
      AND (ts.end_date IS NULL OR NOW() <= ts.end_date)
    ORDER BY ts.start_date DESC -- In case of overlaps, pick the one that started most recently
    LIMIT 1;

    IF v_current_active_subscription IS NOT NULL THEN
        -- An active subscription is found
        SELECT name INTO v_plan_name
        FROM public.subscription_plans
        WHERE id = v_current_active_subscription.subscription_plan_id;

        RETURN QUERY SELECT 'activo'::TEXT, v_current_active_subscription.end_date::TIMESTAMPTZ, v_plan_name::TEXT;
        RETURN;
    END IF;

    -- 2. If no active subscription, find the latest subscription (active or expired) to determine grace/suspended/canceled
    SELECT ts.* INTO v_latest_subscription
    FROM public.tenant_subscriptions ts
    WHERE ts.tenant_id = p_tenant_id AND platform_id = p_platform_id
    ORDER BY ts.end_date DESC NULLS FIRST, ts.created_at DESC
    LIMIT 1;

    IF v_latest_subscription IS NULL THEN
        -- No subscriptions ever found for this tenant
        RETURN QUERY SELECT 'cancelado'::TEXT, NULL::TIMESTAMPTZ, NULL::TEXT;
        RETURN;
    END IF;

    -- Get the plan name for the latest subscription
    SELECT name INTO v_plan_name
    FROM public.subscription_plans
    WHERE id = v_latest_subscription.subscription_plan_id;

    -- Calculate status based on the latest subscription's end_date
    RETURN QUERY
    SELECT
        CASE
            WHEN v_latest_subscription.end_date IS NULL THEN 'activo'::TEXT -- Should have been caught by v_current_active_subscription, but as a fallback
            WHEN NOW() >= v_latest_subscription.start_date AND NOW() <= v_latest_subscription.end_date THEN 'activo'::TEXT -- Should have been caught by v_current_active_subscription, but as a fallback
            WHEN NOW() > v_latest_subscription.end_date AND NOW() <= (v_latest_subscription.end_date + '3 days'::interval) THEN 'gracia'::TEXT
            WHEN NOW() > (v_latest_subscription.end_date + '3 days'::interval) AND NOW() <= (v_latest_subscription.end_date + '3 months'::interval) THEN 'suspendido'::TEXT
            ELSE 'cancelado'::TEXT
        END AS status,
        v_latest_subscription.end_date::TIMESTAMPTZ,
        v_plan_name::TEXT;
END;
$$;



DROP FUNCTION IF EXISTS "public"."get_user_dashboard_stats"("p_tenant_id" "uuid", "p_user_id" "uuid");

CREATE OR REPLACE FUNCTION "public"."get_user_dashboard_stats"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_user_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_stats jsonb;
BEGIN
    SELECT jsonb_build_object(
        'totalCommissions', (SELECT COALESCE(SUM(commission_amount), 0) FROM public.service_user_commissions WHERE tenant_id = p_tenant_id AND platform_id = p_platform_id AND user_id = p_user_id),
        'monthlyCommissions', (SELECT COALESCE(SUM(commission_amount), 0) FROM public.service_user_commissions WHERE tenant_id = p_tenant_id AND platform_id = p_platform_id AND user_id = p_user_id AND date_trunc('month', created_at) = date_trunc('month', CURRENT_DATE))
        -- Add more user-specific stats here as needed
    ) INTO v_stats;

    RETURN v_stats;
END;
$$;



DROP FUNCTION IF EXISTS "public"."link_user_to_tenant"("p_invoking_user_role" "text", "p_tenant_id" "uuid", "p_email" "text", "p_first_name" "text", "p_last_name" "text", "p_password" "text");

CREATE OR REPLACE FUNCTION "public"."link_user_to_tenant"("p_invoking_user_role" "text", "p_tenant_id" "uuid", "p_platform_id" "uuid", "p_email" "text", "p_first_name" "text", "p_last_name" "text", "p_password" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    existing_user_id UUID;
    user_id_to_link UUID;
BEGIN
    -- 1. Guarda de Seguridad de Rol
    IF p_invoking_user_role NOT IN ('super_admin', 'tenant_super_admin', 'tenant_admin') THEN
        RETURN jsonb_build_object('success', false, 'message', 'Acceso denegado. Permisos insuficientes.');
    END IF;

    -- 2. Lógica de Creación o Vinculación de Usuario
    SELECT id INTO existing_user_id FROM auth.users WHERE email = p_email;

    IF existing_user_id IS NULL THEN
        -- Usuario no existe, crearlo
        IF p_password IS NULL OR p_password = '' THEN
            RETURN jsonb_build_object('success', false, 'message', 'La contraseña es obligatoria para nuevos usuarios.');
        END IF;

        -- Insert into public.users, assuming sync_public_user handles auth.users sync
        INSERT INTO public.users (email, first_name, last_name, password_hash)
        VALUES (p_email, p_first_name, p_last_name, crypt(p_password, gen_salt('bf')))
        RETURNING id INTO user_id_to_link;
    ELSE
        -- Usuario ya existe
        user_id_to_link := existing_user_id;
    END IF;

    -- 3. Verificar si el usuario ya está vinculado a este tenant
    IF EXISTS (
        SELECT 1 FROM public.user_assignments
        WHERE user_id = user_id_to_link AND tenant_id = p_tenant_id AND platform_id = p_platform_id
    ) THEN
        RETURN jsonb_build_object('success', false, 'message', 'Este usuario ya es miembro de este negocio.');
    END IF;

    -- 4. Crear la asignación 'pendiente'
    INSERT INTO public.user_assignments (user_id, tenant_id, status)
    VALUES (user_id_to_link, p_tenant_id, 'pending_configuration');

    -- 5. Devolver éxito
    RETURN jsonb_build_object('success', true, 'message', 'Usuario vinculado correctamente. Ahora puedes configurar sus asignaciones.');

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Ha ocurrido un error inesperado: ' || SQLERRM);
END;
$$;



DROP FUNCTION IF EXISTS "public"."list_consent_templates"("p_tenant_id" "uuid");

CREATE OR REPLACE FUNCTION "public"."list_consent_templates"("p_tenant_id" "uuid", "p_platform_id" "uuid") RETURNS SETOF "public"."informed_consent_templates"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    RETURN QUERY
    SELECT *
    FROM public.informed_consent_templates
    WHERE tenant_id = p_tenant_id AND platform_id = p_platform_id
    ORDER BY name;
END;
$$;



DROP FUNCTION IF EXISTS "public"."log_audit_action"("p_action" "text", "p_user_id" "uuid", "p_object_type" "text", "p_object_id" "uuid", "p_old_value" "jsonb", "p_new_value" "jsonb", "p_ip_address" "inet", "p_user_agent" "text", "p_metadata" "jsonb", "p_tenant_id" "uuid", "p_branch_id" "uuid");

CREATE OR REPLACE FUNCTION "public"."log_audit_action"("p_action" "text", "p_user_id" "uuid", "p_object_type" "text" DEFAULT NULL::"text", "p_object_id" "uuid" DEFAULT NULL::"uuid", "p_old_value" "jsonb" DEFAULT NULL::"jsonb", "p_new_value" "jsonb" DEFAULT NULL::"jsonb", "p_ip_address" "inet" DEFAULT NULL::"inet", "p_user_agent" "text" DEFAULT NULL::"text", "p_metadata" "jsonb" DEFAULT NULL::"jsonb", "p_tenant_id" "uuid" DEFAULT NULL::"uuid", "p_platform_id" "uuid" DEFAULT NULL::"uuid", "p_branch_id" "uuid" DEFAULT NULL::"uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    INSERT INTO public.audit_logs (user_id, tenant_id, branch_id, action, object_type, object_id, old_value, new_value, ip_address, user_agent, metadata)
    VALUES (p_user_id, p_tenant_id, p_branch_id, p_action, p_object_type, p_object_id, p_old_value, p_new_value, p_ip_address, p_user_agent, p_metadata);
END;
$$;



DROP FUNCTION IF EXISTS "public"."reactivate_treatment_session"("p_session_id" "uuid", "p_tenant_id" "uuid");

CREATE OR REPLACE FUNCTION "public"."reactivate_treatment_session"("p_session_id" "uuid", "p_tenant_id" "uuid", "p_platform_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    UPDATE public.client_treatment_sessions s
    SET status = 'pending'
    FROM public.client_treatments ct -- JOIN
    WHERE 
        s.id = p_session_id 
        AND s.client_treatment_id = ct.id -- JOIN condition
        AND ct.tenant_id = p_tenant_id AND platform_id = p_platform_id   -- Security check on the parent table
        AND s.status = 'Cancelada';
END;
$$;



DROP FUNCTION IF EXISTS "public"."renew_subscription"("p_tenant_id" "uuid", "p_plan_id" "uuid");

CREATE OR REPLACE FUNCTION "public"."renew_subscription"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_plan_id" "uuid") RETURNS "uuid"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    previous_subscription RECORD;
    new_start_date TIMESTAMPTZ;
    new_end_date TIMESTAMPTZ;
    plan_duration_months INT;
    new_subscription_id UUID;
    generated_invoice_id UUID;
BEGIN
    -- 1. Encontrar la suscripción más reciente (activa o no) para este tenant.
    SELECT * INTO previous_subscription
    FROM public.tenant_subscriptions
    WHERE tenant_id = p_tenant_id AND platform_id = p_platform_id
    ORDER BY end_date DESC NULLS LAST, created_at DESC
    LIMIT 1;

    -- 2. Determinar la fecha de inicio de la nueva suscripción.
    IF previous_subscription IS NOT NULL AND previous_subscription.end_date IS NOT NULL THEN
        -- Renovación: la nueva suscripción empieza donde terminó la anterior.
        new_start_date := previous_subscription.end_date;
    ELSE
        -- Primera suscripción después de un trial o si no hay registro previo.
        new_start_date := now();
    END IF;

    -- 3. Calcular la nueva fecha de finalización.
    SELECT billing_frequency_months INTO plan_duration_months
    FROM public.subscription_plans
    WHERE id = p_plan_id;

    IF plan_duration_months IS NULL THEN
        RAISE EXCEPTION 'No se pudo encontrar la duración para el plan ID %.', p_plan_id;
    END IF;

    new_end_date := new_start_date + (plan_duration_months || ' months')::interval;

    -- 4. Crear la nueva suscripción de pago.
    INSERT INTO public.tenant_subscriptions (
        tenant_id,
        subscription_plan_id,
        is_trial,
        start_date,
        end_date,
        is_active
    ) VALUES (
        p_tenant_id,
        p_plan_id,
        FALSE,
        new_start_date,
        new_end_date,
        TRUE
    ) RETURNING id INTO new_subscription_id;

    -- 5. Actualizar el estado del tenant a 'active'.
    UPDATE public.tenants
    SET subscription_status = 'active'
    WHERE id = p_tenant_id;

    -- 6. Generar la factura para la nueva suscripción.
    SELECT public.generate_invoice_for_subscription(new_subscription_id)
    INTO generated_invoice_id;

    RAISE NOTICE 'Suscripción renovada con ID: %. Factura generada con ID: %', new_subscription_id, generated_invoice_id;

    -- 7. Devolver el ID de la nueva suscripción.
    RETURN new_subscription_id;
END;
$$;



DROP FUNCTION IF EXISTS "public"."return_equipment"("p_tenant_id" "uuid", "p_assignment_id" "uuid", "p_return_date" "date");

CREATE OR REPLACE FUNCTION "public"."return_equipment"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_assignment_id" "uuid", "p_return_date" "date") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    UPDATE equipment_assignments
    SET
        return_date = p_return_date
    WHERE
        id = p_assignment_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;
END;
$$;



DROP FUNCTION IF EXISTS "public"."search_products"("p_tenant_id" "uuid", "p_search_term" "text", "p_show_inactive" boolean, "p_category_name" "text", "p_brand_id" "uuid");

CREATE OR REPLACE FUNCTION "public"."search_products"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_search_term" "text" DEFAULT NULL::"text", "p_show_inactive" boolean DEFAULT false, "p_category_name" "text" DEFAULT NULL::"text", "p_brand_id" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("id" "uuid", "name" "text", "description" "text", "is_active" boolean, "category" "text", "created_at" timestamp with time zone, "updated_at" timestamp with time zone, "cost_price" numeric, "last_purchase_cost" numeric, "average_cost" numeric, "brand_id" "uuid", "barcode" "text", "sku" "text", "tenant_id" "uuid", "name_i18n" "jsonb", "description_i18n" "jsonb", "unit_of_measure_id" "uuid", "package_content_quantity" numeric, "allow_decimal_sale" boolean)
    LANGUAGE "plpgsql"
    AS $_$
DECLARE
    search_words TEXT[];
    word TEXT;
    query_conditions TEXT[] := ARRAY[]::TEXT[];
    final_query TEXT;
BEGIN
    -- Split the search term into words
    IF p_search_term IS NOT NULL AND p_search_term <> '' THEN
        search_words := string_to_array(lower(p_search_term), ' ');
    ELSE
        search_words := ARRAY[]::TEXT[];
    END IF;

    -- Build the query conditions for each word
    FOREACH word IN ARRAY search_words
    LOOP
        IF word <> '' THEN
            query_conditions := array_append(
                query_conditions,
                format(
                    '(p.name ILIKE %1$L OR p.description ILIKE %1$L OR p.sku ILIKE %1$L OR p.barcode ILIKE %1$L)',
                    '%' || word || '%'
                )
            );
        END IF;
    END LOOP;

    -- Construct the final query
    final_query := '
        SELECT
            p.id,
            p.name,
            p.description,
            p.is_active,
            p.category,
            p.created_at,
            p.updated_at,
            p.cost_price,
            p.last_purchase_cost,
            p.average_cost,
            p.brand_id,
            p.barcode,
            p.sku,
            p.tenant_id,
            p.name_i18n,
            p.description_i18n,
            p.unit_of_measure_id,      -- Campo añadido
            p.package_content_quantity, -- Campo añadido
            p.allow_decimal_sale       -- Campo añadido
        FROM
            products p
        WHERE
            p.tenant_id = $1';

    IF NOT p_show_inactive THEN
        final_query := final_query || '
            AND p.is_active = TRUE';
    END IF;

    IF p_category_name IS NOT NULL AND p_category_name <> '' THEN
        final_query := final_query || format('
            AND p.category = %L', p_category_name);
    END IF;

    IF p_brand_id IS NOT NULL THEN
        final_query := final_query || format('
            AND p.brand_id = %L', p_brand_id);
    END IF;

    IF array_length(query_conditions, 1) > 0 THEN
        final_query := final_query || '
            AND (' || array_to_string(query_conditions, ' AND ') || ')';
    END IF;

    final_query := final_query || '
        ORDER BY p.name;';

    -- Execute the query
    RETURN QUERY EXECUTE final_query USING p_tenant_id;
END;
$_$;



DROP FUNCTION IF EXISTS "public"."send_electronic_document"("p_tenant_id" "uuid", "p_document_id" "uuid", "p_provider_slug" "text", "p_document_type" "text");

CREATE OR REPLACE FUNCTION "public"."send_electronic_document"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_document_id" "uuid", "p_provider_slug" "text", "p_document_type" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_provider_config RECORD;
    v_tenant_integration RECORD;
    v_invoice_data JSONB;
    v_request_body JSONB;
    v_request_headers JSONB;
    v_request_url TEXT;
    v_response_content JSONB;
    v_http_method TEXT;
    v_auth_token TEXT;
    v_dataico_account_id TEXT;
    v_decrypted_credentials JSONB;
    v_service_role_key TEXT;
    v_supabase_url TEXT;
    v_edge_function_url TEXT;
    v_edge_function_response JSONB;
BEGIN
    -- 1. Fetch provider configuration from integration_providers
    SELECT
        ip.endpoints,
        ip.config_schema,
        ip.api_schema,
        ihm.method AS http_method,
        ibf.format AS body_format,
        iam.method AS auth_method,
        ip.http_headers,
        ip.authentication_config
    INTO v_provider_config
    FROM public.integration_providers ip
    JOIN public.integration_http_methods ihm ON ip.http_method_id = ihm.id
    JOIN public.integration_body_formats ibf ON ip.body_format_id = ibf.id
    JOIN public.integration_auth_methods iam ON ip.auth_method_id = iam.id
    WHERE ip.slug = p_provider_slug;

    IF v_provider_config.endpoints IS NULL THEN
        RAISE EXCEPTION 'Provider configuration not found for slug: %', p_provider_slug;
    END IF;

    -- 2. Fetch tenant-specific integration credentials
    SELECT encrypted_credentials, nonce, environment
    INTO v_tenant_integration
    FROM public.tenant_integrations
    WHERE tenant_id = p_tenant_id AND platform_id = p_platform_id AND provider = p_provider_slug AND is_active = TRUE;

    IF v_tenant_integration.encrypted_credentials IS NULL THEN
        RAISE EXCEPTION 'Active tenant integration credentials not found for tenant % and provider %', p_tenant_id, p_provider_slug;
    END IF;

    -- 3. Fetch Glamtica invoice data
    SELECT to_jsonb(i.*) || jsonb_build_object('items', (SELECT jsonb_agg(ii.*) FROM public.invoice_items ii WHERE ii.invoice_id = i.id))
    INTO v_invoice_data
    FROM public.invoices i
    WHERE i.id = p_document_id AND i.tenant_id = p_tenant_id AND platform_id = p_platform_id;

    IF v_invoice_data IS NULL THEN
        RAISE EXCEPTION 'Invoice data not found for document ID: %', p_document_id;
    END IF;

    -- 4. Prepare request URL
    v_request_url := v_provider_config.endpoints->>v_tenant_integration.environment;
    IF v_request_url IS NULL THEN
        RAISE EXCEPTION 'Endpoint URL not found for environment %', v_tenant_integration.environment;
    END IF;

    -- 5. Call an Edge Function to handle data mapping, decryption, and external API call
    -- This Edge Function will receive:
    -- - Glamtica invoice data (v_invoice_data)
    -- - Provider's api_schema (v_provider_config.api_schema)
    -- - Provider's http_headers (v_provider_config.http_headers)
    -- - Tenant's encrypted credentials (v_tenant_integration.encrypted_credentials, v_tenant_integration.nonce)
    -- - Dataico_account_id and Auth-token from config_schema (extracted from decrypted credentials)
    -- - Target API URL (v_request_url)
    -- - HTTP Method (v_provider_config.http_method)

    -- Get Supabase URL and Service Role Key for Edge Function invocation
    SELECT value INTO v_supabase_url FROM private.secrets WHERE key = 'supabase_url';
    SELECT value INTO v_service_role_key FROM private.secrets WHERE key = 'service_role_key';

    v_edge_function_url := v_supabase_url || '/functions/v1/map-and-send-dataico'; -- Name of the new Edge Function

    SELECT content INTO v_edge_function_response FROM net.http_post(
        url:= v_edge_function_url,
        body:= jsonb_build_object(
            'tenant_id', p_tenant_id,
            'document_id', p_document_id,
            'glamtica_invoice_data', v_invoice_data,
            'provider_api_schema', v_provider_config.api_schema,
            'provider_http_headers', v_provider_config.http_headers,
            'provider_endpoints', v_provider_config.endpoints,
            'tenant_encrypted_credentials', v_tenant_integration.encrypted_credentials,
            'tenant_nonce', v_tenant_integration.nonce,
            'tenant_environment', v_tenant_integration.environment,
            'http_method', v_provider_config.http_method,
            'body_format', v_provider_config.body_format
        ),
        headers:= jsonb_build_object(
            'Content-Type', 'application/json',
            'Authorization', 'Bearer ' || v_service_role_key -- Authorize Edge Function call
        )
    );

    -- 6. Handle response from Edge Function and update invoice status
    IF (v_edge_function_response->>'success')::BOOLEAN THEN
        -- Update invoice status, provider reference, etc.
        UPDATE public.invoices
        SET
            status = 'sent_to_dataico', -- Or a more specific status
            provider_reference_id = v_edge_function_response->>'dataico_document_id',
            -- Add other fields as needed from the response
            updated_at = NOW()
        WHERE id = p_document_id;

        RETURN jsonb_build_object('success', TRUE, 'message', 'Document sent successfully to Dataico.', 'dataico_response', v_edge_function_response);
    ELSE
        -- Log error and update invoice status
        UPDATE public.invoices
        SET
            status = 'failed_dataico_send',
            error_message = v_edge_function_response->>'error',
            updated_at = NOW()
        WHERE id = p_document_id;

        RAISE EXCEPTION 'Failed to send document to Dataico: %', v_edge_function_response->>'error';
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        -- Log any unexpected errors
        RAISE EXCEPTION 'Error in send_electronic_document: %', SQLERRM;
END;
$$;



DROP FUNCTION IF EXISTS "public"."set_primary_image_for_product"("p_tenant_id" "uuid", "p_product_id" "uuid", "p_image_id" "uuid");

CREATE OR REPLACE FUNCTION "public"."set_primary_image_for_product"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_product_id" "uuid", "p_image_id" "uuid") RETURNS "public"."product_images"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  updated_image product_images; -- Declare a variable to hold the result
BEGIN
  -- First, set all other images for this product to is_primary = false
  UPDATE public.product_images
  SET is_primary = false
  WHERE tenant_id = p_tenant_id AND platform_id = p_platform_id
    AND product_id = p_product_id
    AND id <> p_image_id;

  -- Then, set the specified image to is_primary = true
  UPDATE public.product_images
  SET is_primary = true
  WHERE tenant_id = p_tenant_id AND platform_id = p_platform_id
    AND product_id = p_product_id
    AND id = p_image_id;

  -- Select the updated record INTO the variable
  SELECT *
  INTO updated_image
  FROM public.product_images
  WHERE id = p_image_id;

  -- Return the variable
  RETURN updated_image;
END;
$$;



DROP FUNCTION IF EXISTS "public"."set_primary_image_for_treatment"("p_tenant_id" "uuid", "p_treatment_id" "uuid", "p_image_id" "uuid");

CREATE OR REPLACE FUNCTION "public"."set_primary_image_for_treatment"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_treatment_id" "uuid", "p_image_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    -- Set all images for this treatment to not primary
    UPDATE public.treatment_images
    SET is_primary = FALSE
    WHERE treatment_id = p_treatment_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;

    -- Set the specified image as primary
    UPDATE public.treatment_images
    SET is_primary = TRUE
    WHERE id = p_image_id AND treatment_id = p_treatment_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;

    -- NOTE: The erroneous update to a non-existent 'cover_image_url' column has been removed.
END;
$$;



DROP FUNCTION IF EXISTS "public"."set_user_assignment"("p_target_user_id" "uuid", "p_tenant_id" "uuid", "p_role_id" "uuid", "p_branch_id" "uuid", "p_status" "text");

CREATE OR REPLACE FUNCTION "public"."set_user_assignment"("p_target_user_id" "uuid", "p_tenant_id" "uuid", "p_platform_id" "uuid", "p_role_id" "uuid", "p_branch_id" "uuid" DEFAULT NULL::"uuid", "p_status" "text" DEFAULT 'active'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_caller_id UUID := auth.uid();
    v_caller_role TEXT := (auth.jwt() -> 'app_metadata' ->> 'role');
    v_caller_tenant_id UUID := (auth.jwt() -> 'app_metadata' ->> 'tenant_id')::uuid;
    
    v_target_role_name TEXT;
    v_new_metadata JSONB;
BEGIN
    -- Step 1: Validate that the target role exists
    SELECT name INTO v_target_role_name FROM public.roles WHERE id = p_role_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Role with ID % not found.', p_role_id;
    END IF;

    -- Step 2: Authorization Check (Who is calling this function?)
    IF v_caller_role = 'super_admin' THEN
        -- Super admin can do anything.
        NULL; 
    ELSIF v_caller_role = 'tenant_super_admin' THEN
        -- Tenant super admin can only make assignments within their own tenant.
        IF p_tenant_id != v_caller_tenant_id THEN
            RAISE EXCEPTION 'Permission denied: You can only assign users within your own tenant.';
        END IF;
        -- And they cannot create another super admin.
        IF v_target_role_name = 'super_admin' THEN
            RAISE EXCEPTION 'Permission denied: You cannot assign the super_admin role.';
        END IF;
    ELSE
        -- All other roles are denied.
        RAISE EXCEPTION 'Permission denied: You do not have rights to assign roles.';
    END IF;

    -- Step 3: Construct the new metadata object
    v_new_metadata := jsonb_build_object(
        'role', v_target_role_name,
        'tenant_id', p_tenant_id,
        'branch_id', p_branch_id,
        'assignment_status', p_status
    );

    -- Step 4: Update the user's app_metadata in the auth.users table
    UPDATE auth.users
    SET raw_app_meta_data = raw_app_meta_data || v_new_metadata
    WHERE id = p_target_user_id;

    -- Step 5: Return success
    RETURN jsonb_build_object('success', true, 'message', 'User assignment updated successfully.');

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$;



DROP FUNCTION IF EXISTS "public"."toggle_consent_template_status"("p_tenant_id" "uuid", "p_id" "uuid");

CREATE OR REPLACE FUNCTION "public"."toggle_consent_template_status"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_id" "uuid") RETURNS "public"."informed_consent_templates"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    updated_template public.informed_consent_templates;
BEGIN
    UPDATE public.informed_consent_templates
    SET is_active = NOT is_active
    WHERE id = p_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id
    RETURNING * INTO updated_template;

    RETURN updated_template;
END;
$$;



DROP FUNCTION IF EXISTS "public"."trigger_test_email_for_tenant"("p_tenant_id" "uuid");

CREATE OR REPLACE FUNCTION "public"."trigger_test_email_for_tenant"("p_tenant_id" "uuid", "p_platform_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_super_admin_user RECORD;
    v_full_name TEXT;
BEGIN
    -- Encontrar al super_admin del sistema
    SELECT u.id, (u.raw_user_meta_data->>'first_name') as first_name, (u.raw_user_meta_data->>'last_name') as last_name
    INTO v_super_admin_user
    FROM auth.users u, jsonb_array_elements(u.raw_app_meta_data -> 'assignments') AS assignment
    WHERE (assignment ->> 'role') = 'super_admin'
    LIMIT 1;

    IF v_super_admin_user.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'No se encontró al usuario super_admin del sistema.');
    END IF;

    -- Construir el nombre completo
    v_full_name := TRIM(COALESCE(v_super_admin_user.first_name, '') || ' ' || COALESCE(v_super_admin_user.last_name, ''));
    IF v_full_name = '' THEN
        v_full_name := 'Super Administrador';
    END IF;

    -- Llamar a la función principal de envío de correos
    PERFORM public.trigger_system_email(
        p_recipient_user_id := v_super_admin_user.id,
        p_template_type := 'WELCOME_USER',
        p_template_data := jsonb_build_object('user_name', v_full_name)
    );

    RETURN jsonb_build_object('success', true, 'message', 'El correo de prueba ha sido puesto en la cola de envío.');

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Error inesperado: ' || SQLERRM);
END;
$$;



DROP FUNCTION IF EXISTS "public"."update_combo_branch_prices"("p_tenant_id" "uuid", "p_branch_id" "uuid", "p_combo_id" "uuid", "p_price_overrides" "jsonb");

CREATE OR REPLACE FUNCTION "public"."update_combo_branch_prices"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_branch_id" "uuid", "p_combo_id" "uuid", "p_price_overrides" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    override RECORD;
    target_id UUID;
BEGIN
    -- NOTE: Security is handled by RLS policies and the calling edge function.

    FOR override IN 
        SELECT
            (value->>'product_id')::UUID as product_id,
            (value->>'service_id')::UUID as service_id,
            (value->>'price')::NUMERIC as price
        FROM jsonb_array_elements(p_price_overrides)
    LOOP
        target_id := NULL;

        IF override.product_id IS NOT NULL THEN
            SELECT id INTO target_id FROM branch_combo_item_prices
            WHERE branch_id = p_branch_id AND combo_id = p_combo_id AND product_id = override.product_id;
        ELSIF override.service_id IS NOT NULL THEN
            SELECT id INTO target_id FROM branch_combo_item_prices
            WHERE branch_id = p_branch_id AND combo_id = p_combo_id AND service_id = override.service_id;
        END IF;

        IF target_id IS NOT NULL THEN
            UPDATE branch_combo_item_prices SET price = override.price WHERE id = target_id;
        ELSE
            INSERT INTO branch_combo_item_prices (tenant_id, platform_id, branch_id, combo_id, product_id, service_id, price)
            VALUES (p_tenant_id, p_platform_id, p_branch_id, p_combo_id, override.product_id, override.service_id, override.price);
        END IF;
    END LOOP;
END;
$$;



DROP FUNCTION IF EXISTS "public"."update_consent_template"("p_tenant_id" "uuid", "p_id" "uuid", "p_name" "text", "p_content" "text", "p_fields" "jsonb", "p_is_active" boolean);

CREATE OR REPLACE FUNCTION "public"."update_consent_template"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_id" "uuid", "p_name" "text" DEFAULT NULL::"text", "p_content" "text" DEFAULT NULL::"text", "p_fields" "jsonb" DEFAULT NULL::"jsonb", "p_is_active" boolean DEFAULT NULL::boolean) RETURNS "public"."informed_consent_templates"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    updated_template public.informed_consent_templates;
BEGIN
    UPDATE public.informed_consent_templates
    SET
        name = COALESCE(p_name, name),
        content = COALESCE(p_content, content),
        fields = COALESCE(p_fields, fields),
        is_active = COALESCE(p_is_active, is_active),
        updated_at = now()
    WHERE id = p_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id
    RETURNING * INTO updated_template;

    RETURN updated_template;
END;
$$;



DROP FUNCTION IF EXISTS "public"."update_equipment"("p_tenant_id" "uuid", "p_equipment_id" "uuid", "p_equipment_data" "jsonb");

CREATE OR REPLACE FUNCTION "public"."update_equipment"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_equipment_id" "uuid", "p_equipment_data" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    UPDATE equipment
    SET
        name = p_equipment_data->>'name',
        type_id = (p_equipment_data->>'type_id')::uuid,
        brand = p_equipment_data->>'brand',
        model = p_equipment_data->>'model',
        serial_number = p_equipment_data->>'serial_number',
        purchase_date = (p_equipment_data->>'purchase_date')::date,
        last_maintenance_date = (p_equipment_data->>'last_maintenance_date')::date,
        maintenance_frequency = (p_equipment_data->>'maintenance_frequency')::integer,
        maintenance_frequency_unit = p_equipment_data->>'maintenance_frequency_unit',
        notes = p_equipment_data->>'notes',
        is_active = (p_equipment_data->>'is_active')::boolean,
        updated_at = now()
    WHERE
        id = p_equipment_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;
END;
$$;



DROP FUNCTION IF EXISTS "public"."update_product_category_assignments"("p_tenant_id" "uuid", "p_product_id" "uuid", "p_category_ids" "uuid"[]);

CREATE OR REPLACE FUNCTION "public"."update_product_category_assignments"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_product_id" "uuid", "p_category_ids" "uuid"[]) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    -- First, delete all existing assignments for this product
    DELETE FROM public.product_category_assignments
    WHERE product_id = p_product_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;

    -- Then, insert the new assignments if any are provided
    IF array_length(p_category_ids, 1) > 0 THEN
        INSERT INTO public.product_category_assignments (product_id, category_id, tenant_id)
        SELECT p_product_id, category_id, p_tenant_id
        FROM unnest(p_category_ids) AS t(category_id);
    END IF;
END;
$$;



DROP FUNCTION IF EXISTS "public"."update_product_images_order"("p_tenant_id" "uuid", "p_images_data" "jsonb");

CREATE OR REPLACE FUNCTION "public"."update_product_images_order"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_images_data" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    -- Use a temporary table to hold the new order data
    CREATE TEMP TABLE new_order (
        id uuid,
        sort_order int
    ) ON COMMIT DROP;

    -- Insert the data from the JSONB array into the temp table
    INSERT INTO new_order (id, sort_order)
    SELECT
        (value->>'id')::uuid,
        (value->>'sort_order')::int
    FROM jsonb_array_elements(p_images_data);

    -- Update the product_images table by joining with the temp table
    UPDATE public.product_images AS pi
    SET sort_order = no.sort_order
    FROM new_order AS no
    WHERE pi.id = no.id AND pi.tenant_id = p_tenant_id AND platform_id = p_platform_id;

END;
$$;



DROP FUNCTION IF EXISTS "public"."update_service_images_order"("p_tenant_id" "uuid", "p_images_data" "jsonb");

CREATE OR REPLACE FUNCTION "public"."update_service_images_order"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_images_data" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    CREATE TEMP TABLE new_order (
        id uuid,
        sort_order int
    ) ON COMMIT DROP;

    INSERT INTO new_order (id, sort_order)
    SELECT
        (value->>'id')::uuid,
        (value->>'sort_order')::int
    FROM jsonb_array_elements(p_images_data);

    UPDATE public.service_images AS si
    SET sort_order = no.sort_order
    FROM new_order AS no
    WHERE si.id = no.id AND si.tenant_id = p_tenant_id AND platform_id = p_platform_id;
END;
$$;



DROP FUNCTION IF EXISTS "public"."update_staff_gallery_settings"("p_tenant_id" "uuid", "p_user_id" "uuid", "p_gallery_items" "jsonb");

CREATE OR REPLACE FUNCTION "public"."update_staff_gallery_settings"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_user_id" "uuid", "p_gallery_items" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    item RECORD;
BEGIN
    -- First, set all existing items for this user as not favorite
    UPDATE public.staff_gallery_items
    SET is_favorite = false
    WHERE tenant_id = p_tenant_id AND platform_id = p_platform_id AND user_id = p_user_id;

    -- Now, loop through the provided items and upsert them as favorites with the new order
    FOR item IN SELECT * FROM jsonb_to_recordset(p_gallery_items) AS x(evidence_id UUID, display_order INT)
    LOOP
        INSERT INTO public.staff_gallery_items (
            tenant_id,
            user_id,
            evidence_id,
            display_order,
            is_favorite
        )
        VALUES (
            p_tenant_id,
            p_user_id,
            item.evidence_id,
            item.display_order,
            true
        )
        ON CONFLICT (tenant_id, platform_id, user_id, evidence_id)
        DO UPDATE SET
            display_order = EXCLUDED.display_order,
            is_favorite = EXCLUDED.is_favorite,
            updated_at = NOW();
    END LOOP;
END;
$$;



DROP FUNCTION IF EXISTS "public"."update_tenant_description"("p_tenant_id" "uuid", "p_description" "text");

CREATE OR REPLACE FUNCTION "public"."update_tenant_description"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_description" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    UPDATE public.tenants
    SET
        description = p_description,
        updated_at = now()
    WHERE id = p_tenant_id;
END;
$$;



DROP FUNCTION IF EXISTS "public"."update_tenant_slug"("p_tenant_id" "uuid", "p_slug" "text");

CREATE OR REPLACE FUNCTION "public"."update_tenant_slug"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_slug" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $_$
DECLARE
    v_country_id uuid;
    v_platform_id uuid;
BEGIN
    -- Get the tenant's country and platform
    SELECT country_id, platform_id INTO v_country_id, v_platform_id FROM public.tenants WHERE id = p_tenant_id;

    IF v_platform_id IS NULL OR v_country_id IS NULL THEN
        RAISE EXCEPTION 'Could not determine platform or country for tenant';
    END IF;

    -- Check for slug format
    IF p_slug IS NOT NULL AND (p_slug !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$' OR length(p_slug) <= 2) THEN
        RAISE EXCEPTION 'invalid_slug_format';
    END IF;

    -- Check for uniqueness within the platform and country
    IF p_slug IS NOT NULL AND EXISTS (
        SELECT 1
        FROM public.tenants
        WHERE platform_id = v_platform_id
          AND country_id = v_country_id
          AND slug = p_slug
          AND id != p_tenant_id
    ) THEN
        RAISE EXCEPTION 'slug_already_taken';
    END IF;

    -- Update the tenant's slug
    UPDATE public.tenants
    SET slug = p_slug,
        updated_at = now()
    WHERE id = p_tenant_id;
END;
$_$;



DROP FUNCTION IF EXISTS "public"."update_treatment"("p_treatment_id" "uuid", "p_tenant_id" "uuid", "p_name" "text", "p_description" "text", "p_upfront_price" numeric, "p_financed_price" numeric, "p_sessions" "jsonb");

CREATE OR REPLACE FUNCTION "public"."update_treatment"("p_treatment_id" "uuid", "p_tenant_id" "uuid", "p_platform_id" "uuid", "p_name" "text", "p_description" "text", "p_upfront_price" numeric, "p_financed_price" numeric, "p_sessions" "jsonb") RETURNS "public"."treatments"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    updated_treatment public.treatments;
    session_data jsonb;
    incoming_session_id uuid;
    new_session_id uuid;
    item_data jsonb;
    p_session_ids_to_keep uuid[];
    session_id_to_delete uuid;
BEGIN
    -- First, update the main treatment record
    UPDATE public.treatments
    SET
        name = p_name,
        description = p_description,
        upfront_price = p_upfront_price,
        financed_price = p_financed_price,
        updated_at = now()
    WHERE
        id = p_treatment_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id
    RETURNING * INTO updated_treatment;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Treatment not found or not owned by tenant.';
    END IF;

    p_session_ids_to_keep := ARRAY[]::uuid[];

    -- Upsert sessions and their items from the payload
    IF p_sessions IS NOT NULL AND jsonb_array_length(p_sessions) > 0 THEN
        FOR session_data IN SELECT * FROM jsonb_array_elements(p_sessions) LOOP
            incoming_session_id := (session_data->>'id')::uuid;

            -- Use INSERT ... ON CONFLICT (UPSERT) for the session
            INSERT INTO public.treatment_sessions (
                id,
                treatment_id,
                session_number,
                name,
                description,
                payment_percentage,
                fixed_payment_amount
            )
            VALUES (
                COALESCE(incoming_session_id, gen_random_uuid()),
                updated_treatment.id,
                (session_data->>'session_number')::int,
                session_data->>'name',
                session_data->>'description',
                (NULLIF(session_data->>'payment_percentage', 'null'))::numeric,
                (NULLIF(session_data->>'fixed_payment_amount', 'null'))::numeric
            )
            ON CONFLICT (id) DO UPDATE SET
                session_number = EXCLUDED.session_number,
                name = EXCLUDED.name,
                description = EXCLUDED.description,
                payment_percentage = EXCLUDED.payment_percentage,
                fixed_payment_amount = EXCLUDED.fixed_payment_amount
            RETURNING id INTO new_session_id;
            
            -- Add the ID of the just-processed session to our list of keepers
            p_session_ids_to_keep := array_append(p_session_ids_to_keep, new_session_id);

            -- Cleanly replace items for the current session
            DELETE FROM public.treatment_session_items WHERE session_id = new_session_id;

            IF session_data->'items' IS NOT NULL AND jsonb_array_length(session_data->'items') > 0 THEN
                FOR item_data IN SELECT * FROM jsonb_array_elements(session_data->'items') LOOP
                    INSERT INTO public.treatment_session_items (
                        session_id,
                        product_id,
                        service_id,
                        quantity
                    )
                    VALUES (
                        new_session_id,
                        (item_data->>'product_id')::uuid,
                        (item_data->>'service_id')::uuid,
                        (item_data->>'quantity')::int
                    );
                END LOOP;
            END IF;
        END LOOP;
    END IF;

    -- Safely delete sessions that were removed in the form
    FOR session_id_to_delete IN
        SELECT id FROM public.treatment_sessions
        WHERE treatment_id = p_treatment_id AND NOT (id = ANY(p_session_ids_to_keep))
    LOOP
        -- Check if the session is referenced in any client assignment
        IF EXISTS (
            SELECT 1 FROM public.client_treatment_sessions
            WHERE prototype_session_id = session_id_to_delete
        ) THEN
            RAISE EXCEPTION 'Cannot delete session with ID % because it is currently assigned to at least one client. Please remove assignments before deleting.', session_id_to_delete;
        END IF;

        -- If not referenced, it's safe to delete
        DELETE FROM public.treatment_session_items WHERE session_id = session_id_to_delete;
        DELETE FROM public.treatment_sessions WHERE id = session_id_to_delete;
    END LOOP;

    -- Return the updated main treatment record
    RETURN updated_treatment;
END;
$$;



DROP FUNCTION IF EXISTS "public"."update_treatment_category_assignments"("p_tenant_id" "uuid", "p_treatment_id" "uuid", "p_category_ids" "uuid"[]);

CREATE OR REPLACE FUNCTION "public"."update_treatment_category_assignments"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_treatment_id" "uuid", "p_category_ids" "uuid"[]) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    -- Validate that the treatment belongs to the tenant of the user making the call
    -- The user's tenant is implicitly checked by the RLS policy on the junction table
    IF NOT EXISTS (SELECT 1 FROM public.treatments WHERE id = p_treatment_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id) THEN
        RAISE EXCEPTION 'Treatment not found or access denied.';
    END IF;

    -- First, delete existing assignments for the given treatment
    DELETE FROM public.treatment_category_assignments tca
    WHERE tca.treatment_id = p_treatment_id;

    -- Then, insert the new assignments if any are provided
    IF array_length(p_category_ids, 1) > 0 THEN
        INSERT INTO public.treatment_category_assignments (treatment_id, category_id)
        SELECT p_treatment_id, unnest(p_category_ids);
    END IF;
END;
$$;



DROP FUNCTION IF EXISTS "public"."update_treatment_images_order"("p_tenant_id" "uuid", "p_treatment_id" "uuid", "p_images_data" "jsonb"[]);

CREATE OR REPLACE FUNCTION "public"."update_treatment_images_order"("p_tenant_id" "uuid", "p_platform_id" "uuid", "p_treatment_id" "uuid", "p_images_data" "jsonb"[]) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    image_data jsonb;
BEGIN
    FOR image_data IN SELECT * FROM unnest(p_images_data) LOOP
        UPDATE public.treatment_images
        SET
            sort_order = (image_data->>'sort_order')::int
        WHERE
            id = (image_data->>'id')::uuid
            AND treatment_id = p_treatment_id
            AND tenant_id = p_tenant_id AND platform_id = p_platform_id;
    END LOOP;
END;
$$;



DROP FUNCTION IF EXISTS "public"."update_user_assignment_status"("p_target_user_id" "uuid", "p_tenant_id" "uuid", "p_new_status" "text");

CREATE OR REPLACE FUNCTION "public"."update_user_assignment_status"("p_target_user_id" "uuid", "p_tenant_id" "uuid", "p_platform_id" "uuid", "p_new_status" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_caller_role TEXT := (auth.jwt() -> 'app_metadata' ->> 'role');
    v_caller_tenant_id UUID := (auth.jwt() -> 'app_metadata' ->> 'tenant_id')::uuid;
    v_current_metadata JSONB;
    v_new_metadata JSONB;
BEGIN
    -- Step 2a: Authorization Check
    IF v_caller_role NOT IN ('super_admin', 'tenant_super_admin', 'tenant_admin') THEN
        RAISE EXCEPTION 'Permission denied: You do not have rights to update user status.';
    END IF;

    IF v_caller_role != 'super_admin' AND v_caller_tenant_id != p_tenant_id THEN
        RAISE EXCEPTION 'Permission denied: You can only update users within your own tenant.';
    END IF;

    -- Step 2b: Get the current metadata of the target user
    SELECT raw_app_meta_data INTO v_current_metadata FROM auth.users WHERE id = p_target_user_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Target user not found.';
    END IF;

    -- Step 2c: Construct the new metadata object by updating the status
    v_new_metadata := v_current_metadata || jsonb_build_object('assignment_status', p_new_status);

    -- Step 2d: Update the user's app_metadata
    UPDATE auth.users
    SET raw_app_meta_data = v_new_metadata
    WHERE id = p_target_user_id;

    -- Step 2e: Return success
    RETURN jsonb_build_object('success', true, 'message', 'User assignment status updated successfully.');

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$;



DROP FUNCTION IF EXISTS "public"."update_user_assignments"("p_user_id" "uuid", "p_tenant_id" "uuid", "p_new_assignments" "jsonb");

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
                role_id, 
                branch_id, 
                status,
                base_salary,
                default_product_commission_rate,
                default_service_commission_rate,
                is_schedulable -- The missing field
            )
            VALUES (
                p_user_id,
                p_tenant_id,
                (assignment_data->>'role_id')::uuid,
                CASE
                    WHEN assignment_data->>'branch_id' IS NULL OR assignment_data->>'branch_id' = 'null' THEN NULL
                    ELSE (assignment_data->>'branch_id')::uuid
                END,
                (assignment_data->>'status')::text,
                (assignment_data->>'base_salary')::numeric,
                (assignment_data->>'default_product_commission_rate')::numeric,
                (assignment_data->>'default_service_commission_rate')::numeric,
                COALESCE((assignment_data->>'is_schedulable')::boolean, false) -- The missing value, defaulting to false
            );
        END LOOP;
    END IF;
END;
$$;

