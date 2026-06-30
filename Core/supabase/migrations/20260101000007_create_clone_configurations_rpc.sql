CREATE OR REPLACE FUNCTION clone_configurations_from_platform(
    p_source_platform_id uuid,
    p_target_platform_id uuid,
    p_config_to_clone text[]
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    -- Cursors and record variables
    source_plan record;
    new_plan_id uuid;
    source_tariff record;
BEGIN
    -- Check if 'PLANS' is in the array of things to clone
    IF 'PLANS' = ANY(p_config_to_clone) THEN

        -- 1. Delete existing plans for the target platform
        RAISE NOTICE 'Deleting existing plans for target platform %', p_target_platform_id;
        DELETE FROM public.subscription_plans WHERE platform_id = p_target_platform_id;

        -- 2. Loop through source plans and clone them
        FOR source_plan IN
            SELECT * FROM public.subscription_plans WHERE platform_id = p_source_platform_id
        LOOP
            RAISE NOTICE 'Cloning plan %', source_plan.name;

            -- 3. Insert new plan for the target platform, getting the new ID
            INSERT INTO public.subscription_plans (
                name, description, duration_days, is_active, 
                billing_frequency_months, display_order, grace_period_days, 
                platform_id, is_default_trial
            )
            VALUES (
                source_plan.name, source_plan.description, source_plan.duration_days, source_plan.is_active,
                source_plan.billing_frequency_months, source_plan.display_order, source_plan.grace_period_days,
                p_target_platform_id, source_plan.is_default_trial
            )
            RETURNING id INTO new_plan_id;

            -- 4. Loop through tariffs of the source plan and clone them
            FOR source_tariff IN
                SELECT * FROM public.price_tariffs WHERE subscription_plan_id = source_plan.id
            LOOP
                RAISE NOTICE '  Cloning tariff effective %', source_tariff.effective_date;

                INSERT INTO public.price_tariffs (
                    subscription_plan_id, effective_date, base_price, 
                    currency_id, promotional_price
                )
                VALUES (
                    new_plan_id, source_tariff.effective_date, source_tariff.base_price,
                    source_tariff.currency_id, source_tariff.promotional_price
                );
            END LOOP;
            
        END LOOP;
    END IF;

    -- Logic for cloning other configs ('ASSETS', etc.) will go here later.

END;
$$;
