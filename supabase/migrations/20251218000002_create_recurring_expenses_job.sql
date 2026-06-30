-- 1. Create the function to process recurring expenses
CREATE OR REPLACE FUNCTION public.process_recurring_expenses()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    recurring_expense_record RECORD;
    new_next_generation_date DATE;
BEGIN
    -- Loop through all active recurring expenses that are due
    FOR recurring_expense_record IN
        SELECT *
        FROM public.recurring_expenses
        WHERE is_active = true AND next_generation_date <= NOW()
    LOOP
        -- Insert a new record into the main expenses table
        INSERT INTO public.expenses (tenant_id, branch_id, expense_provider_id, amount, expense_date, description, status)
        VALUES (
            recurring_expense_record.tenant_id,
            recurring_expense_record.branch_id,
            recurring_expense_record.expense_provider_id,
            recurring_expense_record.amount,
            recurring_expense_record.next_generation_date,
            recurring_expense_record.description,
            'pending' -- Default status for a newly generated expense
        );

        -- Calculate the next generation date
        new_next_generation_date := CASE recurring_expense_record.recurrence_type
            WHEN 'daily' THEN recurring_expense_record.next_generation_date + (recurring_expense_record.recurrence_interval * INTERVAL '1 day')
            WHEN 'weekly' THEN recurring_expense_record.next_generation_date + (recurring_expense_record.recurrence_interval * INTERVAL '1 week')
            WHEN 'monthly' THEN recurring_expense_record.next_generation_date + (recurring_expense_record.recurrence_interval * INTERVAL '1 month')
            WHEN 'yearly' THEN recurring_expense_record.next_generation_date + (recurring_expense_record.recurrence_interval * INTERVAL '1 year')
        END;

        -- Update the recurring_expenses record
        UPDATE public.recurring_expenses
        SET
            next_generation_date = new_next_generation_date,
            -- If the new date is past the end_date, deactivate the rule
            is_active = CASE
                WHEN end_date IS NOT NULL AND new_next_generation_date > end_date THEN false
                ELSE is_active
            END
        WHERE id = recurring_expense_record.id;
    END LOOP;
END;
$$;

-- 2. Schedule the cron job to run twice a day (at 2:00 and 14:00 UTC)
SELECT cron.schedule(
    'process-recurring-expenses-job',
    '0 2,14 * * *', -- Every day at 2:00 AM and 2:00 PM UTC
    $$ SELECT public.process_recurring_expenses(); $$
);

-- Note: To unschedule, use: SELECT cron.unschedule('process-recurring-expenses-job');
