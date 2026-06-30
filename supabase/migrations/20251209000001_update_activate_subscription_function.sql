-- Migration to fix the activate_subscription RPC function
-- to align with the new tenant_subscriptions schema.

BEGIN;

-- Drop the old function if it exists, to prevent conflicts.
-- The signature must match the one to be dropped.
DROP FUNCTION IF EXISTS public.activate_subscription(p_tenant_id uuid, p_plan_price_id uuid, p_payment_id uuid);

-- Create the new, corrected function.
CREATE OR REPLACE FUNCTION public.activate_subscription(
    p_tenant_id uuid,
    p_plan_price_id uuid,
    p_payment_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_plan_id UUID;
    v_tenant_country_id UUID;
    v_pcc_id UUID; -- plan_country_configuration_id
    v_billing_frequency_months INT;
    v_current_subscription RECORD;
    v_new_end_date TIMESTAMPTZ;
    v_new_start_date TIMESTAMPTZ;
BEGIN
    -- 1. Get subscription_plan_id from the provided price_tariffs.id
    SELECT subscription_plan_id INTO v_plan_id
    FROM public.price_tariffs
    WHERE id = p_plan_price_id;

    IF v_plan_id IS NULL THEN
        RAISE EXCEPTION 'No se encontró un plan para el plan_price_id (tariff_id): %', p_plan_price_id;
    END IF;

    -- 2. Get the tenant's country
    SELECT country_id INTO v_tenant_country_id
    FROM public.tenants
    WHERE id = p_tenant_id;

    IF v_tenant_country_id IS NULL THEN
        RAISE EXCEPTION 'No se pudo encontrar el país para el tenant: %', p_tenant_id;
    END IF;

    -- 3. Get the specific plan_country_configuration_id for this plan and country
    SELECT id INTO v_pcc_id
    FROM public.plan_country_configurations
    WHERE plan_id = v_plan_id AND country_id = v_tenant_country_id;

    IF v_pcc_id IS NULL THEN
        RAISE EXCEPTION 'No se encontró configuración para el plan % en el país %', v_plan_id, v_tenant_country_id;
    END IF;

    -- 4. Get billing frequency directly from the subscription_plans table
    SELECT billing_frequency_months INTO v_billing_frequency_months
    FROM public.subscription_plans
    WHERE id = v_plan_id;

    IF v_billing_frequency_months IS NULL THEN
        RAISE EXCEPTION 'No se pudo determinar la frecuencia de facturación para el plan %', v_plan_id;
    END IF;

    -- 5. Find the tenant's most recent subscription to check for renewal
    SELECT * INTO v_current_subscription
    FROM public.tenant_subscriptions
    WHERE tenant_id = p_tenant_id
    ORDER BY end_date DESC
    LIMIT 1;

    -- 6. Calculate new start and end dates
    IF v_current_subscription IS NOT NULL AND v_current_subscription.end_date > NOW() THEN
        -- If the current subscription is active, it is extended from its expiration date
        v_new_start_date := v_current_subscription.end_date;
        v_new_end_date := v_current_subscription.end_date + (v_billing_frequency_months || ' months')::interval;
    ELSE
        -- If there is no subscription or it is expired, it starts from today
        v_new_start_date := NOW();
        v_new_end_date := NOW() + (v_billing_frequency_months || ' months')::interval;
    END IF;

    -- 7. Insert the new subscription record with the correct schema
    INSERT INTO public.tenant_subscriptions (
        tenant_id,
        plan_country_configuration_id, -- Correct column
        is_active,
        start_date,
        end_date,
        is_trial
    )
    VALUES (
        p_tenant_id,
        v_pcc_id, -- Correct value
        true,
        v_new_start_date,
        v_new_end_date,
        FALSE
    );

END;
$$;

COMMIT;
