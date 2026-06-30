import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { serve } from 'https://deno.land/std@0.177.0/http/server.ts'

// --- INSTRUCTIONS FOR SCHEDULING ---
// 1. Deploy this function: `supabase functions deploy process-billing-cycles --no-verify-jwt`
// 2. Get the function URL.
// 3. Go to your Supabase project dashboard -> Database -> Function Hooks.
// 4. Create a new hook:
//    - Name: `daily_billing_processor`
//    - HTTP Request:
//      - Method: `POST`
//      - URL: [Your Function URL]
//      - Headers: Add a new header `x-api-key` with a secure secret key.
//    - Trigger:
//      - Type: `cron`
//      - Cron Expression: `0 5 * * *` (This runs at 5 AM UTC every day)
//
// NOTE: This function should be secured with an API key to prevent unauthorized execution.

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    // 1. Secure the function with an API key
    const apiKey = req.headers.get('x-api-key')
    const expectedApiKey = Deno.env.get('CRON_SECRET')
    if (!expectedApiKey || apiKey !== expectedApiKey) {
      return new Response('Unauthorized', { status: 401 })
    }

    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    )

    console.log("Processing billing cycles for today...");
    const today = new Date().toISOString().split('T')[0]; // YYYY-MM-DD

    // 2. Get all subscriptions ending today
    const { data: subscriptions, error: subsError } = await supabaseAdmin
      .from('tenant_subscriptions')
      .select(`
        id,
        tenant_id,
        start_date,
        end_date,
        tenants!inner(
          id,
          countries!inner(
            currencies!inner( code, symbol )
          )
        ),
        plan_country_configurations!inner(
          plan_asset_limits!inner( asset_id, value, plan_assets!inner(asset_key) )
        )
      `)
      .eq('end_date', today)
      .eq('is_active', true);

    if (subsError) throw subsError;

    console.log(`Found ${subscriptions.length} subscriptions ending today.`);

    for (const sub of subscriptions) {
      try {
        const tenantId = sub.tenant_id;
        const billingPeriodStart = sub.start_date;
        const billingPeriodEnd = sub.end_date;
        const limits = sub.plan_country_configurations.plan_asset_limits || [];
        let totalOverageCharge = 0;

        // 3. Get all asset usage for this tenant in the billing period
        const { data: usage, error: usageError } = await supabaseAdmin
          .from('asset_usage_tracking')
          .select('asset_id, quantity_used')
          .eq('tenant_id', tenantId)
          .gte('usage_period_start', billingPeriodStart)
          .lte('usage_period_end', billingPeriodEnd);

        if (usageError) {
          console.error(`Failed to get usage for tenant ${tenantId}:`, usageError.message);
          continue; // Skip to next tenant
        }

        const usageMap = new Map(usage.map(u => [u.asset_id, u.quantity_used]));

        // 4. Calculate overages for each limited asset
        for (const limit of limits) {
          const quantityUsed = usageMap.get(limit.asset_id) || 0;
          const planLimit = limit.value;

          if (quantityUsed > planLimit) {
            const overageAmount = quantityUsed - planLimit;
            const assetKey = limit.plan_assets.asset_key;

            if (!assetKey) {
                console.error(`Could not find asset key for asset_id ${limit.asset_id}`);
                continue;
            }

            // 5. Get the price for the overage
            const { data: priceInfo, error: priceError } = await supabaseAdmin.rpc('get_price_for_tenant_asset', {
              p_tenant_id: tenantId,
              p_asset_key: assetKey
            });

            if (priceError) {
              console.error(`Could not get price for asset ${assetKey} for tenant ${tenantId}:`, priceError.message);
              continue;
            }
            if (!priceInfo || !priceInfo.price || priceInfo.price <= 0) {
              console.log(`No price defined for asset ${assetKey} for tenant ${tenantId}. Skipping overage charge.`);
              continue;
            }
            
            const targetCurrencyCode = sub.tenants.countries.currencies.code;
            let finalPricePerUnit = priceInfo.price;

            if (priceInfo.currency_code !== targetCurrencyCode) {
              const { data: rates, error: ratesError } = await supabaseAdmin
                .from('exchange_rates')
                .select('rate, base_currency_code, target_currency_code')
                .or(`base_currency_code.eq.${priceInfo.currency_code},target_currency_code.eq.${targetCurrencyCode}`);

              if (ratesError) {
                  console.error(`Error fetching exchange rates:`, ratesError.message);
                  continue;
              }

              const rateToUsd = rates.find(r => r.base_currency_code === priceInfo.currency_code && r.target_currency_code === 'USD')?.rate || 1.0;
              const usdToTargetRate = rates.find(r => r.base_currency_code === 'USD' && r.target_currency_code === targetCurrencyCode)?.rate || 1.0;
              finalPricePerUnit = Math.floor(priceInfo.price * rateToUsd * usdToTargetRate) + 0.99;
            }

            totalOverageCharge += overageAmount * finalPricePerUnit;
          }
        }

        // 6. Insert the final charge into the monthly_charges table
        if (totalOverageCharge > 0) {
            const { error: insertError } = await supabaseAdmin
            .from('monthly_charges')
            .insert({
              tenant_id: tenantId,
              billing_period_start: billingPeriodStart,
              billing_period_end: billingPeriodEnd,
              total_overage_charge: totalOverageCharge,
              total_charge: totalOverageCharge, // Assuming base price is handled separately for now
              currency_code: sub.tenants.countries.currencies.code,
              currency_symbol: sub.tenants.countries.currencies.symbol,
              status: 'pending',
            });

            if (insertError) {
                console.error(`Failed to insert charge for tenant ${tenantId}:`, insertError.message);
            } else {
                console.log(`Successfully created charge of ${totalOverageCharge} ${sub.tenants.countries.currencies.code} for tenant ${tenantId}`);
            }
        } else {
            console.log(`No overages to charge for tenant ${tenantId}.`);
        }

      } catch (e) {
        console.error(`An unexpected error occurred while processing subscription for tenant ${sub.tenant_id}:`, e.message);
      }
    }

    return new Response(JSON.stringify({ success: true, message: "Billing cycle processing initiated." }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200,
    })
  } catch (error) {
    console.error('Error in billing cycle processor:', error.message)
    return new Response(JSON.stringify({ success: false, error: error.message }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 500,
    })
  }
})
