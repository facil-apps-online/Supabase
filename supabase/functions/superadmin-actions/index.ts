
import { getCoreSupabaseClient, getTenantSupabaseClient } from '../_shared/supabaseClients.ts';
import { corsHeaders } from '../_shared/cors.ts';

// --- Encryption Helpers ---
const ENCRYPTION_KEY = Deno.env.get('GLAMTICA_ENCRYPTION_KEY');

async function getKey() {
  if (!ENCRYPTION_KEY) {
    throw new Error("GLAMTICA_ENCRYPTION_KEY is not set in environment variables.");
  }
  const keyData = new TextEncoder().encode(ENCRYPTION_KEY.slice(0, 32));
  return await crypto.subtle.importKey(
    "raw",
    keyData,
    { name: "AES-GCM", length: 256 },
    true,
    ["encrypt", "decrypt"]
  );
}

async function encrypt(data: string): Promise<{ encrypted: string; nonce: string }> {
  const key = await getKey();
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const encodedData = new TextEncoder().encode(data);
  const encryptedBuffer = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv: nonce },
    key,
    encodedData
  );

  // Convert buffer to base64
  const encrypted = btoa(String.fromCharCode.apply(null, new Uint8Array(encryptedBuffer)));
  const nonceB64 = btoa(String.fromCharCode.apply(null, nonce));

  return { encrypted, nonce: nonceB64 };
}

console.log("Initializing superadmin-actions function (refactored for distributed architecture)");

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const { action, payload } = await req.json();
    console.log(`superadmin-actions: Received action '${action}'`);

    const coreSupabase = getCoreSupabaseClient();
    const tenantSupabase = getTenantSupabaseClient(); // Keep tenantSupabase for un-refactored actions

    let responseData: any;
    let statusCode = 200;
    const startTime = performance.now();
    let metricsPath = `edge/superadmin-actions/${action}`;

    try {
      switch (action) {
        // --- Platform Actions (Refactored for Core DB) ---
        case 'get_platforms': {
          const { searchTerm } = payload || {};
          let query = coreSupabase.from('platforms').select('*');
          if (searchTerm) query = query.ilike('name', `%${searchTerm}%`);
          const { data, error } = await query.order('name');
          if (error) throw error;
          responseData = data;
          break;
        }
        case 'get_platform_by_id': {
          const { platformId } = payload;
          if (!platformId) throw new Error('platformId is required.');
          const { data, error } = await coreSupabase.from('platforms').select('*').eq('id', platformId).single();
          if (error) throw error;
          responseData = data;
          break;
        }
        case 'create_platform': {
          const { data, error } = await coreSupabase.from('platforms').insert(payload).select().single();
          if (error) throw error;
          responseData = data;
          break;
        }
        case 'update_platform': {
          const { id, ...platformData } = payload;
          if (!id) throw new Error('id is required for update.');
          const { data, error } = await coreSupabase.from('platforms').update(platformData).eq('id', id).select().single();
          if (error) throw error;
          responseData = data;
          break;
        }
        case 'delete_platform': {
          const { id } = payload;
          if (!id) throw new Error('id is required for delete.');
          const { error } = await coreSupabase.from('platforms').delete().eq('id', id);
          if (error) throw error;
          responseData = { success: true };
          break;
        }
        case 'update_platform_settings': {
          const { platformId, settings } = payload;
          if (!platformId || !settings) throw new Error('platformId and settings are required.');
          const { data, error } = await coreSupabase.from('platforms').update(settings).eq('id', platformId).select().single();
          if (error) throw error;
          responseData = data;
          break;
        }

        // --- Platform Countries Actions (Deprecated - managed via PlanCountryConfigurations in Core DB) ---
        case 'get_countries_for_platform':
        case 'assign_country_to_platform':
        case 'remove_country_from_platform': {
          throw new Error(`Action '${action}' is deprecated. Country-platform links are managed via plan configurations in Core DB.`);
        }
        
        // --- System Catalogs (Refactored for Core DB) ---
        case 'get_currencies': {
          let query = coreSupabase.from('currencies').select('*');
          if (payload?.searchTerm) query = query.ilike('name', `%${searchTerm}%`);
          const { data, error } = await query.order('name');
          if (error) throw error;
          responseData = data;
          break;
        }
        case 'create_currency': {
          const { data, error } = await coreSupabase.from('currencies').insert(payload).select().single();
          if (error) throw error;
          responseData = data;
          break;
        }
        case 'update_currency': {
          const { id, ...updateData } = payload;
          if (!id) throw new Error('Currency ID is required.');
          const { data, error } = await coreSupabase.from('currencies').update(updateData).eq('id', id).select().single();
          if (error) throw error;
          responseData = data;
          break;
        }
        case 'delete_currency': {
          const { id } = payload;
          if (!id) throw new Error('Currency ID is required.');
          const { error } = await coreSupabase.from('currencies').delete().eq('id', id);
          if (error) throw error;
          responseData = { success: true };
          break;
        }
        case 'get_countries': {
          let query = coreSupabase.from('countries').select('*, currency:currencies(id, code, symbol)');
          if (payload?.searchTerm) query = query.ilike('name', `%${payload.searchTerm}%`);
          const { data, error } = await query.order('name');
          if (error) throw error;
          responseData = data;
          break;
        }
        case 'create_country': {
          const { data, error } = await coreSupabase.from('countries').insert(payload).select().single();
          if (error) throw error;
          responseData = data;
          break;
        }
        case 'update_country': {
          const { id, ...updateData } = payload;
          if (!id) throw new Error('Country ID is required.');
          const { data, error } = await coreSupabase.from('countries').update(updateData).eq('id', id).select().single();
          if (error) throw error;
          responseData = data;
          break;
        }
        case 'delete_country': {
          const { id } = payload;
          if (!id) throw new Error('Country ID is required.');
          const { error } = await coreSupabase.from('countries').delete().eq('id', id);
          if (error) throw error;
          responseData = { success: true };
          break;
        }
        case 'get_languages': {
          let query = coreSupabase.from('languages').select('*');
          if (payload?.searchTerm) query = query.ilike('name', `%${payload.searchTerm}%`);
          const { data, error } = await query.order('name');
          if (error) throw error;
          responseData = data;
          break;
        }
        case 'create_language': {
          const { data, error } = await coreSupabase.from('languages').insert(payload).select().single();
          if (error) throw error;
          responseData = data;
          break;
        }
        case 'update_language': {
          const { id, ...updateData } = payload;
          if (!id) throw new Error('Language ID is required.');
          const { data, error } = await coreSupabase.from('languages').update(updateData).eq('id', id).select().single();
          if (error) throw error;
          responseData = data;
          break;
        }
        case 'delete_language': {
          const { id } = payload;
          if (!id) throw new Error('Language ID is required.');
          const { error } = await coreSupabase.from('languages').delete().eq('id', id);
          if (error) throw error;
          responseData = { success: true };
          break;
        }

        // --- Subscription Plan Actions (Refactored for Core DB) ---
        case 'get_subscription_plans_by_platform': {
            const { platformId } = payload;
            if (!platformId) throw new Error('platformId is required.');
            const { data, error } = await coreSupabase
              .from('subscription_plans')
              .select('*')
              .eq('platform_id', platformId)
              .order('created_at', { ascending: false });
            if (error) throw error;
            responseData = data;
            break;
          }
  
          case 'get_subscription_plan_by_id': {
            const { planId } = payload;
            if (!planId) throw new Error('planId is required.');
            const { data, error } = await coreSupabase
              .from('subscription_plans')
              .select('*')
              .eq('id', planId)
              .single();
            if (error) throw error;
            responseData = data;
            break;
          }
  
          case 'create_subscription_plan': {
            const { planData } = payload;
            if (!planData || !planData.platform_id) throw new Error('Plan data with platform_id is required.');
            const { data, error } = await coreSupabase.from('subscription_plans').insert(planData).select().single();
            if (error) throw error;
            responseData = data;
            break;
          }
  
          case 'update_subscription_plan': {
            const { planId, planData } = payload;
            if (!planId || !planData) throw new Error('planId and planData are required.');
            const { data, error } = await coreSupabase.from('subscription_plans').update(planData).eq('id', planId).select().single();
            if (error) throw error;
            responseData = data;
            break;
          }
  
          // --- Asset Purpose Actions (Refactored for Core DB) ---
          case 'get_asset_purposes': {
            const { data, error } = await coreSupabase.from('asset_purposes').select('*').order('purpose_key', { ascending: true });
            if (error) throw error;
            responseData = data;
            break;
          }
          case 'create_asset_purpose': {
            const { purposeData } = payload;
            if (!purposeData) throw new Error('purposeData is required.');
            const { data, error } = await coreSupabase.from('asset_purposes').insert(purposeData).select().single();
            if (error) throw error;
            responseData = data;
            break;
          }
          case 'update_asset_purpose': {
            const { purposeId, purposeData } = payload;
            if (!purposeId || !purposeData) throw new Error('purposeId and purposeData are required.');
            const { data, error } = await coreSupabase.from('asset_purposes').update(purposeData).eq('id', purposeId).select().single();
            if (error) throw error;
            responseData = data;
            break;
          }
          case 'delete_asset_purpose': {
            const { purposeId } = payload;
            if (!purposeId) throw new Error('purposeId is required.');
            const { error } = await coreSupabase.from('asset_purposes').delete().eq('id', purposeId);
            if (error) throw error;
            responseData = { success: true };
            break;
          }
  
          // --- Plan Asset Actions (Refactored for Core DB) ---
          case 'get_plan_assets_by_platform': {
            const { platformId } = payload;
            if (!platformId) throw new Error('platformId is required.');
            const { data, error } = await coreSupabase.from('plan_assets').select('*, asset_purposes(purpose_key)').eq('platform_id', platformId).order('created_at', { ascending: false });
            if (error) throw error;
            responseData = data.map(asset => ({
              ...asset,
              asset_purpose_key: asset.asset_purposes?.purpose_key,
              asset_purposes: undefined,
            }));
            break;
          }
          case 'create_plan_asset': {
            const { assetData } = payload;
            if (!assetData || !assetData.platform_id) throw new Error('Asset data with platform_id is required.');
            const { data, error } = await coreSupabase.from('plan_assets').insert(assetData).select().single();
            if (error) throw error;
            responseData = data;
            break;
          }
          case 'update_plan_asset': {
            const { assetId, assetData } = payload;
            if (!assetId || !assetData) throw new Error('assetId and assetData are required.');
            const { data, error } = await coreSupabase.from('plan_assets').update(assetData).eq('id', assetId).select().single();
            if (error) throw error;
            responseData = data;
            break;
          }
          case 'delete_plan_asset': {
            const { assetId } = payload;
            if (!assetId) throw new Error('assetId is required.');
            const { error } = await coreSupabase.from('plan_assets').delete().eq('id', assetId);
            if (error) throw error;
            responseData = { success: true };
            break;
          }
  
          // --- Plan Configuration Actions (Country-Centric) (Refactored for Core DB) ---
          case 'get_plan_details': {
            const { planId } = payload;
            if (!planId) throw new Error('planId is required.');

            const { data: planData, error: planError } = await coreSupabase.from('subscription_plans').select('*, platforms(id, name)').eq('id', planId).single();
            if (planError) throw planError;

            const platformId = planData.platforms.id;
            const { data: platformCountries, error: countriesError } = await coreSupabase.from('countries').select('id, name, iso_code'); // Now directly from core countries
            if (countriesError) throw countriesError;
            
            const countries = platformCountries;
            const { data: countryConfigs, error: configsError } = await coreSupabase
              .from('plan_country_configurations')
              .select('*, plan_asset_limits(*, plan_assets(*), bonuses:plan_asset_bonuses(*))')
              .eq('plan_id', planId);
            if (configsError) throw configsError;

            const configurationsByCountry = {};
            for (const country of countries) {
              const config = countryConfigs.find(c => c.country_id === country.id);
              if (config) {
                configurationsByCountry[country.id] = {
                  ...config,
                  asset_limits: (config.plan_asset_limits || []).map(limit => ({
                    ...limit,
                    asset_name: limit.plan_assets?.name,
                    asset_description: limit.plan_assets?.description,
                    data_type: limit.plan_assets?.data_type,
                    bonuses: limit.bonuses || [],
                  }))
                };
              } else {
                configurationsByCountry[country.id] = {
                  id: null, plan_id: planId, country_id: country.id, is_active: false, features: [], asset_limits: []
                };
              }
            }
            responseData = { plan: planData, countries: countries, configurations: configurationsByCountry };
            break;
          }
          case 'update_plan_details': {
            const { planId, configurations } = payload;
            if (!planId || !configurations) throw new Error('planId and configurations are required.');

            for (const countryId in configurations) {
              const config = configurations[countryId];
              const hasFeatures = config.features && config.features.some(f => f.trim() !== '');
              const hasValuedLimits = config.asset_limits && config.asset_limits.some(l => l.value && String(l.value) !== '0' && String(l.value) !== 'false');
              
              if (!hasFeatures && !hasValuedLimits && !config.id) { // Nothing to insert if no data and no existing ID
                  continue;
              }

              if (!hasFeatures && !hasValuedLimits && config.id) { // Delete if no features/limits and it exists
                await coreSupabase.from('plan_country_configurations').delete().eq('id', config.id);
                continue;
              }
  
              const { data: upsertedConfig, error: upsertConfigError } = await coreSupabase
                .from('plan_country_configurations')
                .upsert({
                  id: config.id || undefined, plan_id: planId, country_id: countryId, is_active: true, features: config.features || [],
                })
                .select()
                .single();
              if (upsertConfigError) throw upsertConfigError;
              const planCountryConfigId = upsertedConfig.id;
  
              await coreSupabase.from('plan_asset_limits').delete().eq('plan_country_config_id', planCountryConfigId);
  
              if (config.asset_limits && config.asset_limits.length > 0) {
                const limitsToInsert = config.asset_limits
                  .filter((limit: any) => limit.asset_id && limit.value && String(limit.value) !== '0' && String(limit.value) !== 'false')
                  .map((limit: any) => ({
                    plan_country_config_id: planCountryConfigId, asset_id: limit.asset_id, value: String(limit.value),
                    extra_unit_price: limit.extra_unit_price || 0, overage_unit_price: limit.overage_unit_price || 0,
                  }));
  
                if (limitsToInsert.length > 0) {
                  const { data: insertedLimits, error: insertLimitsError } = await coreSupabase
                    .from('plan_asset_limits')
                    .insert(limitsToInsert)
                    .select('id, asset_id');
                  if (insertLimitsError) throw insertLimitsError;
  
                  const assetIdToLimitIdMap = new Map(insertedLimits.map(l => [l.asset_id, l.id]));
                  const bonusesToInsert: any[] = [];
  
                  for (const limit of config.asset_limits) {
                    if (limit.bonuses && limit.bonuses.length > 0) {
                      const sourceAssetLimitId = assetIdToLimitIdMap.get(limit.asset_id);
                      if (sourceAssetLimitId) {
                        for (const bonus of limit.bonuses) {
                          bonusesToInsert.push({
                            source_asset_limit_id: sourceAssetLimitId, bonus_asset_id: bonus.bonus_asset_id, quantity: bonus.quantity,
                          });
                        }
                      }
                    }
                  }
                  if (bonusesToInsert.length > 0) {
                    const { error: insertBonusesError } = await coreSupabase.from('plan_asset_bonuses').insert(bonusesToInsert);
                    if (insertBonusesError) throw insertBonusesError;
                  }
                }
              }
            }
            responseData = { success: true };
            break;
          }
  
          // --- Tariff Actions (New Versioned Pricing) (Refactored for Core DB) ---
          case 'get_tariffs_for_plan': {
            const { planId } = payload;
            if (!planId) throw new Error('planId is required.');
            
            const { data: tariffs, error: tariffsError } = await coreSupabase
              .from('price_tariffs')
              .select('*')
              .eq('subscription_plan_id', planId)
              .order('effective_date', { ascending: false });
  
            if (tariffsError) throw tariffsError;
  
            const tariffsWithDetails = await Promise.all(
              tariffs.map(async (tariff) => {
                const { data: assetPrices, error: assetPricesError } = await coreSupabase
                  .from('tariff_asset_prices')
                  .select('*, currencies(code, symbol)')
                  .eq('tariff_id', tariff.id);
                if (assetPricesError) throw assetPricesError;
                return { 
                    ...tariff, 
                    asset_prices: assetPrices.map(ap => ({
                        ...ap,
                        currency_code: ap.currencies?.code,
                        currency_symbol: ap.currencies?.symbol,
                        currencies: undefined
                    })) || [] 
                };
              })
            );
            responseData = tariffsWithDetails;
            break;
          }
  
          case 'schedule_new_tariff': {
            const { tariffData, assetPricesData } = payload;
            if (!tariffData || !assetPricesData) throw new Error('tariffData and assetPricesData are required.');
            const { data: newTariff, error: tariffError } = await coreSupabase
              .from('price_tariffs')
              .insert(tariffData)
              .select()
              .single();
            if (tariffError) throw tariffError;
            const pricesToInsert = assetPricesData.map((price: any) => ({
              ...price,
              tariff_id: newTariff.id,
            }));
            const { error: pricesError } = await coreSupabase
              .from('tariff_asset_prices')
              .insert(pricesToInsert);
            if (pricesError) {
              await coreSupabase.from('price_tariffs').delete().eq('id', newTariff.id);
              throw pricesError;
            }
            responseData = { success: true, tariff: newTariff };
            break;
          }


        // --- Tenant Actions (Refactored for Core DB where relevant, otherwise tenantSupabase) ---
        case 'get_tenants': {
          const { searchTerm, platformId } = payload || {};
          let query = coreSupabase // Querying Core tenants table
            .from('tenants')
            .select(`
              id, name, slug, is_system_owner,
              platform:platforms(id, name),
              country:countries(id, name, iso_code)
            `);
          if (searchTerm) query = query.ilike('name', `%${searchTerm}%`);
          if (platformId) query = query.eq('platform_id', platformId);
          const { data, error } = await query.order('name');
          if (error) throw error;
          responseData = data;
          break;
        }

        case 'get_tenant_by_id': {
          const { id } = payload;
          if (!id) throw new Error('Tenant ID is required.');
          const { data: coreTenant, error: coreError } = await coreSupabase
            .from('tenants')
            .select(`
              *,
              platform:platforms(id, name),
              country:countries(id, name, iso_code)
            `)
            .eq('id', id)
            .single();
          if (coreError) throw coreError;
          responseData = coreTenant;
          break;
        }
        
        case 'set_system_owner': {
          const { tenantId, platformId } = payload || {};
          if (!tenantId || !platformId) throw new Error('tenantId and platformId are required.');
          // Update in Core DB's simplified tenants table
          const { error: coreUpdateError } = await coreSupabase.from('tenants').update({ is_system_owner: true }).eq('id', tenantId);
          if (coreUpdateError) throw coreUpdateError; // Propagate error

          // Also call RPC on Tenant DB to update its is_system_owner flag for backward compatibility
          // assuming the RPC will still exist in the Tenant DB for now.
          const { error: rpcError } = await tenantSupabase.rpc('set_system_owner', { p_new_owner_tenant_id: tenantId, p_platform_id: platformId });
          if (rpcError) console.error("Failed to update is_system_owner in Tenant DB via RPC:", rpcError); // Log, but don't block
          
          responseData = { success: true };
          break;
        }


        // --- Tenant Subscription Actions (Refactored for Core DB) ---
        case 'get_subscriptions_by_tenant': {
          const { tenantId } = payload;
          if (!tenantId) throw new Error('tenantId is required.');
          const { data, error } = await coreSupabase
            .from('tenant_subscriptions')
            .select(`
              id, start_date, end_date, is_active, is_trial, status,
              plan_country_configurations!inner(
                subscription_plans(name)
              )
            `)
            .eq('tenant_id', tenantId)
            .order('start_date', { ascending: false });
          if (error) throw error;
          responseData = data.map((sub: any) => ({
            id: sub.id,
            start_date: sub.start_date,
            end_date: sub.end_date,
            is_active: sub.is_active,
            is_trial: sub.is_trial,
            plan_name: sub.plan_country_configurations?.subscription_plans?.name || 'N/A',
            status: sub.status
          }));
          break;
        }

        // --- Email Template Actions (Refactored for Core DB) ---
        case 'get_platform_email_templates': {
            const { platformId } = payload;
            if (!platformId) throw new Error('platformId is required.');
            const { data, error } = await coreSupabase
              .from('email_templates')
              .select('*')
              .eq('platform_id', platformId);
            if (error) throw error;
            responseData = data;
            break;
          }
  
          case 'create_platform_email_template': {
            const { templateData } = payload; // ownerTenantId is not needed for Core DB
            if (!templateData) throw new Error('templateData is required.');
            const { data, error } = await coreSupabase
              .from('email_templates')
              .insert(templateData) // Insert directly
              .select()
              .single();
            if (error) throw error;
            responseData = data;
            break;
          }
  
          case 'update_platform_email_template': {
            const { templateId, templateData } = payload;
            if (!templateId || !templateData) throw new Error('templateId and templateData are required.');
            const { data, error } = await coreSupabase
              .from('email_templates')
              .update(templateData)
              .eq('id', templateId)
              .select()
              .single();
            if (error) throw error;
            responseData = data;
            break;
          }
  
          case 'delete_platform_email_template': {
            const { templateId } = payload;
            if (!templateId) throw new Error('templateId is required.');
            const { error } = await coreSupabase
              .from('email_templates')
              .delete()
              .eq('id', templateId);
            if (error) throw error;
            responseData = { success: true };
            break;
          }

        // --- Global Integrations Actions (Refactored for Core DB - defining integrations) ---
        case 'get_global_integrations': {
            const { data: providers, error: providersError } = await coreSupabase // integration_providers is Core
              .from('integration_providers')
              .select('*, category:integration_categories(id, name, slug)') // 'country' join removed here, as countries are now in Core
              .order('name');
            if (providersError) throw providersError;
            const { data: countries, error: countriesError } = await coreSupabase.from('countries').select('*').order('name'); // Countries is Core
            if (countriesError) throw countriesError;
            const { data: categories, error: categoriesError } = await coreSupabase.from('integration_categories').select('*').order('name'); // Categories is Core
            if (categoriesError) throw categoriesError;
            responseData = { providers, countries, categories };
            break;
          }
  
          case 'get_integration_provider': {
            const { id } = payload;
            if (!id) throw new Error('id is required.');
            const { data, error } = await coreSupabase // integration_providers is Core
              .from('integration_providers')
              .select('*, country:countries(id, name, iso_code), category:integration_categories(id, name, slug)')
              .eq('id', id)
              .single();
            if (error) throw error;
            responseData = data;
            break;
          }
  
          case 'upsert_integration_provider': {
            const { provider } = payload;
            if (!provider) throw new Error('provider is required.');
            const { data, error } = await coreSupabase // integration_providers is Core
              .from('integration_providers')
              .upsert(provider)
              .select()
              .single();
            if (error) throw error;
            responseData = data;
            break;
          }
  
          case 'get_integration_http_methods': {
            const { data, error } = await coreSupabase.from('integration_http_methods').select('*'); // Core DB
            if (error) throw error;
            responseData = data;
            break;
          }
  
          case 'get_integration_body_formats': {
            const { data, error } = await coreSupabase.from('integration_body_formats').select('*'); // Core DB
            if (error) throw error;
            responseData = data;
            break;
          }
  
          case 'get_integration_auth_methods': {
            const { data, error } = await coreSupabase.from('integration_auth_methods').select('*'); // Core DB
            if (error) throw error;
            responseData = data;
            break;
          }
  
          case 'get_integration_categories': {
            const { data, error } = await coreSupabase.from('integration_categories').select('*'); // Core DB
            if (error) throw error;
            responseData = data;
            break;
          }
  
          case 'delete_integration_category': {
            const { id } = payload;
            if (!id) throw new Error('id is required.');
            const { error } = await coreSupabase.from('integration_categories').delete().eq('id', id); // Core DB
            if (error) throw error;
            responseData = { success: true };
            break;
          }
  
          case 'upsert_integration_category': {
            const { category } = payload;
            if (!category) throw new Error('category is required.');
            const { data, error } = await coreSupabase.from('integration_categories').upsert(category).select().single(); // Core DB
            if (error) throw error;
            responseData = data;
            break;
          }

        // --- Tenant Integrations Actions (Using tenantSupabase) ---
        case 'get_tenant_integrations': {
          const { tenantId } = payload;
          if (!tenantId) throw new Error('tenantId is required.');
          const { data, error } = await tenantSupabase.rpc('get_tenant_integrations', { p_tenant_id: tenantId });
          if (error) throw error;
          responseData = data;
          break;
        }

        case 'save_whatsapp_integration': {
            const { tenant_id, credentials } = payload;
            if (!tenant_id || !credentials) throw new Error('tenant_id and credentials are required.');
            const { access_token, account_id, phone_number_id } = credentials;
            if (!access_token || !account_id || !phone_number_id) throw new Error('credentials must include access_token, account_id, and phone_number_id.');
            const { encrypted, nonce } = await encrypt(JSON.stringify(credentials));
            const { data, error } = await tenantSupabase
                .from('tenant_integrations')
                .upsert({ tenant_id: tenant_id, provider: 'meta_whatsapp', environment: 'production', encrypted_credentials: encrypted, nonce: nonce, is_active: true }, { onConflict: 'tenant_id, provider, environment' })
                .select()
                .single();
            if (error) throw error;
            responseData = { success: true, ...data };
            break;
        }

        case 'delete_tenant_integration': {
          const { integrationId } = payload;
          if (!integrationId) throw new Error('integrationId is required.');
          const { error } = await tenantSupabase.from('tenant_integrations').delete().eq('id', integrationId);
          if (error) throw error;
          responseData = { success: true };
          break;
        }

        case 'get_tenant_users': {
          const { tenantId } = payload;
          if (!tenantId) throw new Error('tenantId is required.');
          const { data, error } = await tenantSupabase.rpc('get_tenant_users', { target_tenant_id: tenantId });
          if (error) throw error;
          responseData = data;
          break;
        }

        case 'get_platform_level_assignments': {
          const { data, error } = await tenantSupabase.rpc('get_platform_level_assignments');
          if (error) throw error;
          responseData = data;
          break;
        }

        case 'assign_platform_role': {
          const { userId, role, assignments } = payload;
          if (!userId || !role || !assignments) throw new Error('userId, role, and assignments are required.');
          const { data: user, error: fetchError } = await tenantSupabase.auth.admin.getUserById(userId);
          if (fetchError) throw fetchError;
          let existingAssignments = user.user.app_metadata?.assignments || [];

          if (role === 'investor') {
            const investorData = assignments.map((a: any) => ({
              user_id: userId, platform_id: a.platformId, investment_share: a.stake / 100,
            }));
            const { error } = await tenantSupabase.from('investor_platform_shares').upsert(investorData);
            if (error) throw error;
            const newAssignment = assignments.map((a: any) => ({
              assignment_id: crypto.randomUUID(), tenant_id: null, tenant_name: null, role_id: null, role: 'investor', platform_id: a.platformId, platform_name: a.platform_name, branch_id: null, branch_name: null, status: 'active', stake_percentage: a.stake,
            }));
            existingAssignments = existingAssignments.filter((ea: any) => !(ea.role === 'investor' && newAssignment.some((na: any) => na.platform_id === ea.platform_id)));
            existingAssignments.push(...newAssignment);
          } else if (role === 'app_super_admin') {
            const { data: roleData, error: roleError } = await tenantSupabase.from('roles').select('id').eq('name', 'app_super_admin').single();
            if (roleError) throw new Error('Could not find app_super_admin role.');
            const roleId = roleData.id;
            const platformAssignments = assignments.map((a: any) => ({
              user_id: userId, platform_id: a.platformId, role_id: roleId,
            }));
            const { error } = await tenantSupabase.from('platform_assignments').upsert(platformAssignments);
            if (error) throw error;
            const newAssignment = assignments.map((a: any) => ({
              assignment_id: crypto.randomUUID(), tenant_id: null, tenant_name: null, role_id: roleId, role: 'app_super_admin', platform_id: a.platformId, platform_name: a.platform_name, branch_id: null, branch_name: null, status: 'active',
            }));
            existingAssignments = existingAssignments.filter((ea: any) => !(ea.role === 'app_super_admin' && newAssignment.some((na: any) => na.platform_id === ea.platform_id)));
            existingAssignments.push(...newAssignment);
          } else {
            throw new Error(`Role ${role} is not a platform-level role.`);
          }
          const { error: updateError } = await tenantSupabase.auth.admin.updateUserById(userId, {
            app_metadata: { ...user.user.app_metadata, assignments: existingAssignments },
          });
          if (updateError) throw updateError;
          responseData = { success: true };
          break;
        }

        case 'remove_platform_assignment': {
            const { userId, role, platformId } = payload;
            if (!userId || !role || !platformId) throw new Error('userId, role, and platformId are required.');
            if (role === 'investor') {
                const { error } = await tenantSupabase.from('investor_platform_shares').delete().match({ user_id: userId, platform_id: platformId });
                if (error) throw error;
            } else if (role === 'app_super_admin') {
                const { error } = await tenantSupabase.from('platform_assignments').delete().match({ user_id: userId, platform_id: platformId });
                if (error) throw error;
            }
            const { data: user, error: fetchError } = await tenantSupabase.auth.admin.getUserById(userId);
            if (fetchError) throw fetchError;
            const existingAssignments = user.user.app_metadata?.assignments || [];
            const finalAssignments = existingAssignments.filter((ea: any) => 
                !(ea.platform_id === platformId && ea.role === role)
            );
            const { error: updateError } = await tenantSupabase.auth.admin.updateUserById(userId, {
                app_metadata: { ...user.user.app_metadata, assignments: finalAssignments },
            });
            if (updateError) throw updateError;
            responseData = { success: true };
            break;
        }

        case 'update_investor_stake': {
          const { userId, platformId, stake } = payload;
          if (!userId || !platformId || stake === undefined) throw new Error('userId, platformId, and stake are required.');
          const { error } = await tenantSupabase.from('investor_platform_shares').update({ investment_share: stake / 100 }).match({ user_id: userId, platform_id: platformId });
          if (error) throw error;
          responseData = { success: true };
          break;
        }

        case 'assign_super_admin_role': {
          const { userId } = payload;
          if (!userId) throw new Error('userId is required.');
          const { data: roleData, error: roleError } = await tenantSupabase.from('roles').select('id').eq('name', 'super_admin').single();
          if (roleError) throw new Error('Could not find super_admin role.');
          const { error: assignmentError } = await tenantSupabase.from('user_assignments').insert({ user_id: userId, role_id: roleData.id });
          if (assignmentError) throw error;
          responseData = { success: true };
          break;
        }

        case 'assign_vendor_role': {
          const { userId, tenantId } = payload;
          if (!userId || !tenantId) throw new Error('userId and tenantId are required.');
          const { error } = await tenantSupabase.from('vendor_tenants').insert({ user_id: userId, tenant_id: tenantId });
          if (error) throw error;
          responseData = { success: true };
          break;
        }

        case 'assign_vendor_platform_commissions': {
          const { userId, commissions } = payload;
          if (!userId || !commissions) throw new Error('userId and commissions are required.');
          const vendorData = commissions.map((c: any) => ({
            user_id: userId, platform_id: c.platformId, first_payment_commission_rate: c.first_payment_commission_rate / 100, recurring_payment_commission_rate: c.recurring_payment_commission_rate / 100,
          }));
          const { error } = await tenantSupabase.from('vendor_platform_commissions').upsert(vendorData, { onConflict: 'user_id, platform_id' });
          if (error) throw error;
          responseData = { success: true };
          break;
        }

        case 'delete_user': {
          const { userId } = payload;
          if (!userId) throw new Error('userId is required for deletion.');
          const { error } = await tenantSupabase.auth.admin.deleteUser(userId);
          if (error) throw error;
          responseData = { success: true };
          break;
        }

        case 'create_user': {
          const { email, password, fullName, role, assignments } = payload;
          if (!email || !password || !fullName || !role) throw new Error('email, password, fullName, and role are required.');
          const nameParts = fullName.split(' ');
          const firstName = nameParts.shift() || '';
          const lastName = nameParts.join(' ');
          const { data: newUser, error: createError } = await tenantSupabase.auth.admin.createUser({
            email, password, email_confirm: true, user_metadata: { full_name: fullName, first_name: firstName, last_name: lastName },
          });
          if (createError) throw createError;
          const userId = newUser.user.id;
          const { data: roleData, error: roleError } = await tenantSupabase.from('roles').select('id').eq('name', role).single();
          if (roleError) throw new Error('Could not find role.'); // Changed
          const roleId = roleData.id;
          if (role === 'app_super_admin' && assignments) {
            const platformAssignments = assignments.map((platformId: string) => ({ user_id: userId, platform_id: platformId, role_id: roleId }));
            const { error } = await tenantSupabase.from('platform_assignments').insert(platformAssignments);
            if (error) throw error;
          } else if (role === 'investor' && assignments) {
            const investorData = assignments.map((a: any) => ({
              user_id: userId, platform_id: a.platformId, investment_share: a.stake / 100,
            }));
            const { error } = await tenantSupabase.from('investor_platform_shares').insert(investorData);
            if (error) throw error;
          } else if (role === 'vendor' && assignments) {
            const vendorData = assignments.map((platformId: string) => ({
              user_id: userId, platform_id: platformId,
            }));
            const { error } = await tenantSupabase.from('vendor_platform_commissions').insert(vendorData);
            if (error) throw error;
          }
          responseData = { success: true, user: newUser.user };
          break;
        }

        case 'update_user_name': {
          const { userId, firstName, lastName } = payload;
          if (!userId || !firstName || !lastName) throw new Error('userId, firstName, and lastName are required.');
          const { error } = await tenantSupabase.rpc('update_user_name', {
            user_id_to_update: userId, new_first_name: firstName, new_last_name: lastName,
          });
          if (error) throw error;
          responseData = { success: true };
          break;
        }

        case 'get_vendor_platform_commissions': {
          const { userId } = payload;
          if (!userId) throw new Error('userId is required.');
          const { data, error } = await tenantSupabase
            .from('vendor_platform_commissions')
            .select(`*, platform:platforms (name)`)
            .eq('user_id', userId);
          if (error) error; // Changed to throw error directly
          const remappedData = data.map(d => ({ ...d, platform_name: d.platform.name, platform: undefined, }));
          responseData = remappedData;
          break;
        }

        case 'update_vendor_platform_commission': {
          const { commissionId, updates } = payload;
          if (!commissionId || !updates) throw new Error('commissionId and updates are required.');
          const { data, error } = await tenantSupabase.from('vendor_platform_commissions').update(updates).eq('id', commissionId).select().single();
          if (error) throw error;
          responseData = data;
          break;
        }

        case 'remove_vendor_platform_commission': {
          const { commissionId } = payload;
          if (!commissionId) throw new Error('commissionId is required.');
          const { error } = await tenantSupabase.from('vendor_platform_commissions').delete().eq('id', commissionId);
          if (error) throw error;
          responseData = { success: true };
          break;
        }

        case 'get_api_health_stats': {
          const { data, error } = await tenantSupabase.rpc('get_api_health_stats');
          if (error) throw error;
          responseData = data;
          break;
        }

        case 'get_investor_dashboard_data': {
          const { platformData } = payload;
          if (!platformData || !Array.isArray(platformData) || platformData.length === 0) throw new Error('platformData is required and must be a non-empty array.');
          const platformIds = platformData.map((p: any) => p.platform_id);
          const { data: platformNames, error: platformNamesError } = await coreSupabase.from('platforms').select('id, name').in('id', platformIds); // Core DB
          if (platformNamesError) throw platformNamesError;
          const platformNameMap = new Map(platformNames.map((p: any) => [p.id, p.name]));
          const now = new Date();
          const currentMonthStart = new Date(now.getFullYear(), now.getMonth(), 1);
          const currentMonthEnd = new Date(now.getFullYear(), now.getMonth() + 1, 0, 23, 59, 59, 999);
          const prevMonthStart = new Date(now.getFullYear(), now.getMonth() - 1, 1);
          const prevMonthEnd = new Date(now.getFullYear(), now.getMonth(), 0, 23, 59, 59, 999);
          const { data: payments, error: paymentsError } = await coreSupabase // Payments is Core DB
            .from('payments')
            .select(`
              amount_in_cents, payment_date,
              tenant:tenants!payments_tenant_id_fkey(platform_id, is_system_owner)
            `)
            .eq('status', 'Completed')
            .in('tenant.platform_id', platformIds)
            .gte('payment_date', prevMonthStart.toISOString())
            .lte('payment_date', currentMonthEnd.toISOString());
          if (paymentsError) throw paymentsError;

          let currentMonthSales = 0; let previousMonthSales = 0; let currentMonthCommission = 0; let previousMonthCommission = 0;
          const stakeMap = new Map(platformData.map((p: any) => [p.platform_id, p.stake_percentage]));
          payments.forEach((payment: any) => {
            const platformId = payment.tenant?.platform_id;
            const isSystemOwner = payment.tenant?.is_system_owner;
            const paymentDate = new Date(payment.payment_date);
            const amount = payment.amount_in_cents / 100;
            if (isSystemOwner) return;
            const stakePercentage = stakeMap.get(platformId) || 0;
            const commission = amount * (stakePercentage / 100);
            if (paymentDate >= currentMonthStart && paymentDate <= currentMonthEnd) {
              currentMonthSales += amount; currentMonthCommission += commission;
            } else if (paymentDate >= prevMonthStart && paymentDate <= prevMonthEnd) {
              previousMonthSales += amount; previousMonthCommission += commission;
            }
          });
          responseData = {
            currentMonthSales, previousMonthSales, currentMonthCommission, previousMonthCommission,
            platforms: platformData.map((p: any) => ({
              id: p.platform_id, name: platformNameMap.get(p.platform_id) || 'Unknown Platform', stake_percentage: p.stake_percentage,
            })),
          };
          break;
        }

        case 'insert_system_alert': {
          const { platform_id, type, message, details } = payload;
          if (!platform_id || !type || !message) throw new Error('Platform ID, type, and message are required for inserting a system alert.');
          const { data, error } = await coreSupabase.from('system_alerts').insert({ platform_id, type, message, details }).select().single(); // Core DB
          if (error) throw error;
          responseData = data;
          break;
        }

        case 'get_system_alerts': {
          const { platform_id, type, is_resolved } = payload;
          let query = coreSupabase.from('system_alerts').select('*, platforms(name)').order('created_at', { ascending: false }); // Core DB
          if (platform_id) query = query.eq('platform_id', platform_id);
          if (type) query = query.eq('type', type);
          if (is_resolved !== undefined) query = query.eq('is_resolved', is_resolved);
          const { data, error } = await query;
          if (error) throw error;
          responseData = data.map((alert: any) => ({
            ...alert, platform_name: alert.platforms?.name || 'N/A', platforms: undefined,
          }));
          break;
        }

        case 'update_system_alert_status': {
          const { id, is_resolved, resolved_by } = payload;
          if (!id || is_resolved === undefined || !resolved_by) throw new Error('ID, is_resolved status, and resolved_by are required to update system alert status.');
          const { data, error } = await coreSupabase.from('system_alerts').update({ is_resolved, resolved_at: new Date().toISOString(), resolved_by }).eq('id', id).select().single(); // Core DB
          if (error) throw error;
          responseData = data;
          break;
        }

        default:
          statusCode = 400;
          throw new Error(`Invalid action: ${action}`);
      }
    } catch (error) {
      statusCode = error.code?.startsWith('PGRST') ? 400 : 500;
      console.error(`Error in action '${action}':`, error.message);
      responseData = { success: false, message: error.message };
    } finally {
      const endTime = performance.now();
      const responseTimeMs = endTime - startTime;
      console.log(`superadmin-actions: Action '${action}' took ${responseTimeMs.toFixed(2)}ms, status: ${statusCode}`);
      await tenantSupabase.from('api_request_metrics').insert({
        path: metricsPath, method: 'POST', status_code: statusCode, response_time_ms: responseTimeMs
      });
    }

    return new Response(JSON.stringify(responseData), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: statusCode,
    });

  } catch (error) {
    return new Response(JSON.stringify({
      success: false, message: error.message,
    }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 400,
    });
  }
});
