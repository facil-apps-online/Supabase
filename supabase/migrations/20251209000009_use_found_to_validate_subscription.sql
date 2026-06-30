-- Final version of activate_subscription using FOUND variable for validation.

BEGIN;

DROP FUNCTION IF EXISTS public.activate_subscription(p_tenant_id uuid, p_plan_price_id uuid, p_payment_id uuid);

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
    WHERE tenant_id = p_tenant_id AND is_active = true
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
    WHERE tenant_id = p_tenant_id AND is_active = true;

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

COMMIT;
