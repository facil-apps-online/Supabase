-- Fix expense date types to support timezones properly

-- Alter expenses table
ALTER TABLE public.expenses
ALTER COLUMN expense_date TYPE timestamp with time zone;

-- Alter recurring_expenses table
ALTER TABLE public.recurring_expenses
ALTER COLUMN start_date TYPE timestamp with time zone,
ALTER COLUMN end_date TYPE timestamp with time zone,
ALTER COLUMN next_generation_date TYPE timestamp with time zone;
