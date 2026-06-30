import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { Sha256 } from 'https://deno.land/std@0.160.0/hash/sha256.ts';
import { getSupabaseAdminClient } from '../_shared/supabaseClients.ts';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

// Helper to validate the incoming request
function validateRequest(body: any) {
  const { tenantId, redirectUrl, userId, currency = 'COP', planId, extraItems } = body;
  
  if (!tenantId || !redirectUrl || !userId) {
    throw new Error('tenantId, redirectUrl, y userId son requeridos.');
  }

  // We require a planId to establish the base price context, even if just checking out assets
  // If mixed cart is supported later, this might change.
  if (!planId) {
     throw new Error('planId es requerido para calcular el precio base.');
  }

  return { tenantId, redirectUrl, userId, currency, planId, extraItems: extraItems || [] };
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    // Initialize Supabase clients
    // In Core context, we only need the Core Admin Client to access tenants, platforms, tariffs, etc.
    const coreSupabase = getSupabaseAdminClient();

    const body = await req.json();
    const { tenantId, redirectUrl, userId, currency, planId, extraItems } = validateRequest(body);

    console.log(`[Checkout] Processing for Tenant: ${tenantId}, Plan: ${planId}`);

    // --- 1. Get Context (Platform & Tenant) ---
    // Get the current tenant's platform_id from the Core DB (Single Source of Truth)
    // We use Core DB 'tenants' table which mirrors key info.
    const { data: tenant, error: tenantError } = await coreSupabase
      .from('tenants')
      .select('id, platform_id, name')
      .eq('id', tenantId)
      .single();

    if (tenantError || !tenant) {
        throw new Error(`Tenant ${tenantId} not found in Core DB.`);
    }
    const platformId = tenant.platform_id;

    // --- 2. Calculate Price (Backend Logic) ---
    let totalAmountInCents = 0;
    const lineItems = [];
    let actionsSnapshot = [];

    // 2a. Get Plan Price (Base)
    // Find the active tariff for this plan and currency
    const { data: tariff, error: tariffError } = await coreSupabase
        .from('price_tariffs')
        .select(`
            id, 
            base_price, 
            currency_id, 
            currencies!inner(code),
            subscription_plans(name)
        `)
        .eq('subscription_plan_id', planId)
        .eq('currencies.code', currency) // Filter by currency code match via join
        .lte('effective_date', new Date().toISOString()) // Tariff must be effective
        .order('effective_date', { ascending: false }) // Get the most recent one
        .limit(1)
        .single();

    if (tariffError || !tariff) {
        console.error("Tariff lookup failed:", tariffError);
        throw new Error(`No se encontró una tarifa válida para el plan ${planId} en moneda ${currency}.`);
    }

    const planPrice = Number(tariff.base_price) * 100; // Convert to cents (assuming base_price is numeric decimal)
    totalAmountInCents += planPrice;
    
    lineItems.push({
        type: 'PLAN',
        id: planId,
        name: tariff.subscription_plans?.name || 'Suscripción',
        quantity: 1,
        unit_amount: planPrice,
        total_amount: planPrice
    });

    // Action: Activate/Renew Plan
    actionsSnapshot.push({
        type: 'ACTIVATE_PLAN',
        plan_id: planId,
        tenant_id: tenantId
    });

    // 2b. Calculate Extra Assets (if any)
    if (extraItems && extraItems.length > 0) {
        // Fetch asset prices for this tariff
        const { data: assetPrices, error: assetPricesError } = await coreSupabase
            .from('tariff_asset_prices')
            .select('asset_id, extra_unit_price, plan_assets(name, asset_key)')
            .eq('tariff_id', tariff.id)
            .in('asset_id', extraItems.map((i: any) => i.assetId));

        if (assetPricesError) throw assetPricesError;

        const assetPriceMap = new Map(assetPrices.map((ap: any) => [ap.asset_id, ap]));

        for (const item of extraItems) {
            const priceInfo = assetPriceMap.get(item.assetId);
            if (!priceInfo) {
                console.warn(`Price not found for asset ${item.assetId} in tariff ${tariff.id}. Skipping.`);
                continue;
            }

            const unitPrice = Number(priceInfo.extra_unit_price) * 100; // Cents
            const quantity = item.quantity || 1;
            const itemTotal = unitPrice * quantity;

            totalAmountInCents += itemTotal;
            lineItems.push({
                type: 'EXTRA_ASSET',
                id: item.assetId,
                name: priceInfo.plan_assets?.name || 'Extra Asset',
                asset_key: priceInfo.plan_assets?.asset_key,
                quantity: quantity,
                unit_amount: unitPrice,
                total_amount: itemTotal
            });

            // Action: Add Asset Capacity
            actionsSnapshot.push({
                type: 'ADD_ASSET_CAPACITY',
                asset_id: item.assetId,
                quantity: quantity,
                tenant_id: tenantId
            });
        }
    }

    if (totalAmountInCents <= 0) {
        throw new Error("El monto total a pagar es inválido (0 o negativo).");
    }

    // --- 3. Get Wompi Credentials ---
    // Get owner tenant for the platform
    const { data: ownerTenantCore, error: ownerErrorCore } = await coreSupabase
      .from('tenants')
      .select('id')
      .eq('platform_id', platformId)
      .eq('is_system_owner', true)
      .single();

    if (ownerErrorCore || !ownerTenantCore) {
      throw new Error(`Tenant propietario no encontrado para plataforma ${platformId}.`);
    }

    // Get active Wompi integration
    const { data: integration, error: integrationError } = await coreSupabase
      .from('tenant_integrations')
      .select('encrypted_credentials, nonce, environment')
      .eq('tenant_id', ownerTenantCore.id) 
      .eq('provider', 'wompi-co')
      .eq('is_active', true)
      .single();

    if (integrationError || !integration) {
      throw new Error(`Integración Wompi activa no encontrada para el owner ${ownerTenantCore.id}.`);
    }

    const { environment } = integration;

    // Decrypt Credentials
    const { data: decryptedResponse, error: decryptError } = await coreSupabase.functions.invoke('decrypt-secret', { 
        body: { encryptedData: integration.encrypted_credentials, iv: integration.nonce } 
    });
    
    if (decryptError) throw new Error(`Error desencriptando credenciales: ${decryptError.message}`);
    
    const credentials = JSON.parse(decryptedResponse.decryptedText);
    const { public_key, integrity_secret } = credentials;
    if (!public_key || !integrity_secret) throw new Error('Credenciales de Wompi incompletas (falta public_key o integrity_secret).');

    // Get platform name for reference
    const { data: platformData, error: platformError } = await coreSupabase
      .from('platforms')
      .select('name')
      .eq('id', platformId)
      .single();

    if (platformError || !platformData) throw new Error('Plataforma no encontrada.');

    // --- 4. Create Transaction Record (Unified Table) ---
    const reference = `${platformData.name}_${tenantId}_${Date.now()}`;
    
    const { error: transactionError } = await coreSupabase
      .from('transactions')
      .insert({
        tenant_id: tenantId,
        platform_id: platformId,
        status: 'PENDING',
        amount_in_cents: totalAmountInCents,
        currency: currency,
        reference: reference,
        provider: 'wompi-co',
        environment: environment,
        metadata: { 
            initiated_by: userId,
            plan_id: planId 
        },
        line_items: lineItems,
        actions_snapshot: actionsSnapshot
      });

    if (transactionError) {
        throw new Error(`Error guardando transacción en BD: ${transactionError.message}`);
    }

    // --- 5. Generate Wompi Signature ---
    // Signature = SHA256(Reference + AmountInCents + Currency + IntegritySecret)
    const concatenation = `${reference}${totalAmountInCents}${currency}${integrity_secret}`;
    const signature = new Sha256().update(concatenation).hex();

    const checkoutData = {
      'public-key': public_key,
      'currency': currency,
      'amount-in-cents': totalAmountInCents,
      'reference': reference,
      'redirect-url': redirectUrl,
      'signature:integrity': signature,
    };

    return new Response(JSON.stringify({ success: true, checkoutData }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200,
    });

  } catch (error) {
    console.error('Error en wompi-generate-checkout:', error.message);
    return new Response(JSON.stringify({ success: false, error: error.message }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 500,
    });
  }
});