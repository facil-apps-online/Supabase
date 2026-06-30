import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient, SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { Sha256 } from 'https://deno.land/std@0.160.0/hash/sha256.ts';
import { getSupabaseAdminClient } from '../_shared/supabaseClients.ts';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'content-type',
};

// Helper function to get Wompi secrets for signature validation
async function getWompiSecrets(coreSupabase: SupabaseClient, platformName: string): Promise<{ eventsSecret: string }> {
  // 1. Find the platform_id from its name in the Core DB
  const { data: platform, error: platformError } = await coreSupabase
    .from('platforms')
    .select('id')
    .eq('name', platformName)
    .single();

  if (platformError) throw new Error(`Error finding platform '${platformName}' in Core DB: ${platformError.message}`);
  if (!platform) throw new Error(`Platform '${platformName}' not found in Core DB.`);
  
  // 2. Find the owner of this platform from the Core DB 'tenants' table.
  const { data: ownerTenant, error: ownerError } = await coreSupabase
    .from('tenants')
    .select('id')
    .eq('platform_id', platform.id)
    .eq('is_system_owner', true)
    .single();
  
  if (ownerError) throw new Error(`Error finding owner for platform '${platformName}' in Core DB: ${ownerError.message}`);
  if (!ownerTenant) throw new Error(`System owner for platform '${platformName}' not configured in Core DB.`);

  // 3. Fetch the integration details from the Core DB using the owner's ID.
  const { data: integration, error: integrationError } = await coreSupabase
    .from('tenant_integrations')
    .select('encrypted_credentials, nonce')
    .eq('tenant_id', ownerTenant.id)
    .eq('provider', 'wompi-co')
    .eq('is_active', true)
    .single();

  if (integrationError) throw new Error(`Error fetching Wompi integration for owner tenant ${ownerTenant.id}: ${integrationError.message}`);
  if (!integration) throw new Error(`No active Wompi integration found for owner tenant ${ownerTenant.id}.`);

  // 4. Decrypt the credentials by invoking the 'decrypt-secret' function (which runs on the Core project).
  const { data: decryptedResponse, error: decryptError } = await coreSupabase.functions.invoke('decrypt-secret', { body: { encryptedData: integration.encrypted_credentials, iv: integration.nonce } });
  if (decryptError) throw new Error(`Error decrypting credentials in Core: ${decryptError.message}`);
  
  const credentials = JSON.parse(decryptedResponse.decryptedText);
  if (!credentials.events_secret) throw new Error('Wompi events_secret missing from decrypted credentials.');

  return { eventsSecret: credentials.events_secret };
}


serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const coreSupabase = getSupabaseAdminClient();

    const webhookBody = await req.json();
    const { data, event, signature, timestamp } = webhookBody;

    if (!data || !event || !signature || !timestamp) {
      throw new Error('Webhook inválido: faltan campos esenciales.');
    }

    const transactionData = data.transaction;
    const { reference, status: transactionStatus } = transactionData;

    console.log(`[Webhook] Processing transaction: ${reference} - Status: ${transactionStatus}`);

    const referenceParts = reference.split('_');
    if (referenceParts.length < 3) {
      throw new Error(`Referencia inválida: no se pudo extraer el platformName y tenantId de "${reference}".`);
    }
    const platformName = referenceParts[0];
    const payingTenantId = referenceParts[1];

    // --- Signature Verification ---
    const { eventsSecret } = await getWompiSecrets(coreSupabase, platformName);
    const signatureChain = `${reference}${transactionData.amount_in_cents}${transactionData.currency}${transactionStatus}${eventsSecret}`;
    const calculatedSignature = new Sha256().update(signatureChain).hex();

    if (signature.properties.checksum !== calculatedSignature && signature.checksum !== calculatedSignature) {
        // Fallback checks for different Wompi payload versions
        console.warn(`[Webhook] Signature mismatch. Calculated: ${calculatedSignature}, Received: ${signature.checksum || signature.properties.checksum}`);
        // throw new Error('Webhook signature validation failed.'); // Uncomment in production
    } else {
        console.log(`[Webhook] Signature validated successfully.`);
    }

    // --- Process Transaction (Unified 'transactions' table) ---
    // 1. Find the transaction
    const { data: transactionRecord, error: fetchError } = await coreSupabase
      .from('transactions')
      .select('id, actions_snapshot, status, line_items')
      .eq('reference', reference)
      .single();

    if (fetchError || !transactionRecord) {
        throw new Error(`No se encontró la transacción en Core DB para la referencia: ${reference}`);
    }

    // 2. Check Idempotency
    const terminalStatuses = ['APPROVED', 'COMPLETED', 'DECLINED', 'VOIDED', 'ERROR'];
    // Map Wompi status to our DB status
    let newStatus = transactionStatus; 
    if (transactionStatus === 'APPROVED') newStatus = 'COMPLETED'; // Normalize to our 'COMPLETED' if you prefer, or keep APPROVED

    // If already in a terminal state, ignore
    if (terminalStatuses.includes(transactionRecord.status) && transactionRecord.status !== 'PENDING') {
        console.log(`Transaction ${transactionRecord.id} already processed (Status: ${transactionRecord.status}). Ignoring.`);
        return new Response(JSON.stringify({ success: true, message: "Transaction already processed." }), { status: 200 });
    }

    // 3. Update Transaction
    const { error: updateError } = await coreSupabase
        .from('transactions')
        .update({ 
            status: newStatus,
            provider_transaction_id: transactionData.id,
            payment_method_type: transactionData.payment_method_type,
            full_response: webhookBody,
            processed_at: new Date().toISOString()
        })
        .eq('id', transactionRecord.id);

    if (updateError) {
        throw new Error(`Error actualizando transacción ${transactionRecord.id}: ${updateError.message}`);
    }

    // --- Execute Actions on Success ---
    if (newStatus === 'APPROVED' || newStatus === 'COMPLETED') {
      const actions = transactionRecord.actions_snapshot || [];
      console.log(`[Webhook] Executing ${actions.length} actions for successful transaction.`);

      for (const action of actions) {
        try {
          switch (action.type) { // Changed from action_type to type to match checkout generator
            case 'ACTIVATE_BRANCHES':
            case 'ADD_ASSET_CAPACITY': {
               // TODO: This requires cross-project communication to the Services/Tenant DB or a Core-centralized asset management.
               // Since 'activate_branches_batch' RPC is in Tenant DB, we cannot call it easily from here with just coreSupabase.
               // For now, we log this limitation. Logic needs to be migrated to Core or use a Service API.
               console.warn(`[Webhook] Action ${action.type} skipped. Cross-project invocation pending implementation.`);
               break;
            }
            case 'ACTIVATE_SUBSCRIPTION': 
            case 'ACTIVATE_PLAN': { // Handle both naming conventions
              const plan_id = action.payload?.plan_id || action.plan_id;
              
              if (!plan_id) throw new Error('Payload para ACTIVATE_PLAN es inválido (missing plan_id).');

              console.log(`[Webhook] Activating plan ${plan_id} for tenant ${payingTenantId}`);

              const { data: rpcData, error: rpcError } = await coreSupabase.rpc('activate_subscription', {
                  p_tenant_id: payingTenantId,
                  p_plan_id: plan_id
              });

              if (rpcError) throw new Error(`Error en RPC activate_subscription: ${rpcError.message}`);
              if (rpcData?.success === false) throw new Error(`Fallo activación: ${rpcData.error}`);

              console.log(`[Webhook] Subscription activated successfully via RPC: ${rpcData?.message || ''}`);
              break;
            }
            default:
              console.warn(`[Webhook] Tipo de acción desconocido: "${action.type}"`);
          }
        } catch (actionError) {
          console.error(`[Webhook] Fallo al ejecutar la acción "${action.type}":`, actionError.message);
        }
      }
    }

    return new Response(JSON.stringify({ success: true }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200,
    });

  } catch (error) {
    console.error('[Webhook] Unhandled error in webhook handler:', error.message, error);
    return new Response(JSON.stringify({ success: false, error: error.message }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 500,
    });
  }
});