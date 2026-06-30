-- Migration to create the RPC function for atomically incrementing asset usage.
-- Version: 20251104000006

CREATE OR REPLACE FUNCTION public.increment_asset_usage_rpc(
    p_tenant_id uuid,
    p_asset_key text,
    p_quantity_to_add bigint
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_asset_id uuid;
    v_current_period_start date;
    v_current_period_end date;
BEGIN
    -- 1. Find the asset_id from the asset_key
    SELECT id INTO v_asset_id
    FROM public.plan_assets
    WHERE asset_key = p_asset_key;

    IF v_asset_id IS NULL THEN
        RAISE EXCEPTION 'Invalid asset_key: %', p_asset_key;
    END IF;

    -- 2. Determine the current billing period (assuming monthly, starting on the 1st)
    v_current_period_start := date_trunc('month', current_date);
    v_current_period_end := (date_trunc('month', current_date) + interval '1 month' - interval '1 day')::date;

    -- 3. Atomically insert or update the usage record
    INSERT INTO public.asset_usage_tracking (
        tenant_id,
        asset_id,
        usage_period_start,
        usage_period_end,
        quantity_used
    )
    VALUES (
        p_tenant_id,
        v_asset_id,
        v_current_period_start,
        v_current_period_end,
        p_quantity_to_add
    )
    ON CONFLICT (tenant_id, asset_id, usage_period_start)
    DO UPDATE SET
        quantity_used = asset_usage_tracking.quantity_used + p_quantity_to_add,
        updated_at = now();

END;
$$;
