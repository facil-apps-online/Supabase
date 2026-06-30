import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';

// --- Encryption Helpers ---
const ENCRYPTION_KEY = Deno.env.get('FAO_ENCRYPTION_KEY');

async function getKey() {
  if (!ENCRYPTION_KEY) {
    throw new Error("FAO_ENCRYPTION_KEY is not set in environment variables.");
  }
  const keyData = new TextEncoder().encode(ENCRYPTION_KEY.slice(0, 32));
  return await crypto.subtle.importKey("raw", keyData, { name: "AES-GCM", length: 256 }, true, ["encrypt", "decrypt"]);
}

async function decrypt(encrypted: string, nonceB64: string): Promise<any> {
  const key = await getKey();
  const nonce = new Uint8Array(Array.from(atob(nonceB64), c => c.charCodeAt(0)));
  const encryptedData = new Uint8Array(Array.from(atob(encrypted), c => c.charCodeAt(0)));
  const decryptedBuffer = await crypto.subtle.decrypt({ name: "AES-GCM", iv: nonce }, key, encryptedData);
  const decryptedString = new TextDecoder().decode(decryptedBuffer);
  return JSON.parse(decryptedString);
}

// --- WhatsApp Credentials Helper (Multi-Platform Version) ---
const credentialsCache = new Map<string, { creds: any; timestamp: number }>();

async function getWhatsappCredentials(supabaseAdmin: any, tenantId: string) {
  const now = Date.now();

  // 1. Find platform_id for the given tenant
  const { data: tenant, error: tenantError } = await supabaseAdmin
    .from('tenants')
    .select('platform_id')
    .eq('id', tenantId)
    .single();

  if (tenantError || !tenant) {
    throw new Error(`Could not find tenant or platform for tenant_id: ${tenantId}`);
  }
  
  const platformId = tenant.platform_id;
  if (!platformId) {
      throw new Error(`Tenant ${tenantId} is not associated with any platform.`);
  }

  // 2. Check cache for this platform's credentials
  const cached = credentialsCache.get(platformId);
  if (cached && (now - cached.timestamp < 300000)) { // 5 minute cache
    return cached.creds;
  }

  // 3. Find owner tenant for the platform
  const { data: ownerTenant, error: ownerError } = await supabaseAdmin
    .from('tenants')
    .select('id')
    .eq('platform_id', platformId)
    .eq('is_system_owner', true)
    .single();

  if (ownerError || !ownerTenant) {
    throw new Error(`Could not find system owner for platform_id: ${platformId}`);
  }

  // 4. Get integration for the owner tenant
  const { data: integration, error: integrationError } = await supabaseAdmin
    .from('tenant_integrations')
    .select('encrypted_credentials, nonce')
    .eq('tenant_id', ownerTenant.id)
    .eq('provider', 'meta_whatsapp')
    .eq('is_active', true)
    .single();

  if (integrationError) {
    throw new Error(`No active WhatsApp integration for owner of platform ${platformId}: ${integrationError.message}`);
  }

  // 5. Decrypt and cache
  const credentials = await decrypt(integration.encrypted_credentials, integration.nonce);
  credentialsCache.set(platformId, { creds: credentials, timestamp: now });

  return credentials;
}

// --- Main Handler ---
serve(async (req) => {
  const supabaseAdmin = createClient(
    Deno.env.get('SUPABASE_URL') ?? '',
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
  );

  try {
    // 1. Get pending jobs
    const { data: jobs, error: fetchError } = await supabaseAdmin
      .from('client_whatsapp_queue')
      .select('*')
      .eq('status', 'PENDING')
      .limit(50); // Process up to 50 jobs at a time

    if (fetchError) throw fetchError;
    if (!jobs || jobs.length === 0) {
      return new Response(JSON.stringify({ message: "No pending jobs." }), { headers: { "Content-Type": "application/json" } });
    }

    // 2. Group jobs by tenant to fetch credentials efficiently
    const jobsByTenant = jobs.reduce((acc, job) => {
      if (!acc[job.tenant_id]) {
        acc[job.tenant_id] = [];
      }
      acc[job.tenant_id].push(job);
      return acc;
    }, {} as Record<string, any[]>);

    // 3. Process each group
    const processingPromises = Object.entries(jobsByTenant).map(async ([tenantId, tenantJobs]) => {
      try {
        const credentials = await getWhatsappCredentials(supabaseAdmin, tenantId);
        const { access_token, phone_number_id } = credentials;

        for (const job of tenantJobs) {
          try {
            await supabaseAdmin.from('client_whatsapp_queue').update({ status: 'PROCESSING', last_attempt_at: new Date().toISOString() }).eq('id', job.id);

            const payload = {
              messaging_product: "whatsapp",
              to: job.recipient_phone_number,
              type: "template",
              template: {
                name: job.template_name,
                language: { code: "es" },
                components: [{ type: "body", parameters: job.template_params?.parameters || [] }]
              }
            };

            const metaApiUrl = `https://graph.facebook.com/v19.0/${phone_number_id}/messages`;
            const response = await fetch(metaApiUrl, {
              method: 'POST',
              headers: { 'Authorization': `Bearer ${access_token}`, 'Content-Type': 'application/json' },
              body: JSON.stringify(payload)
            });

            if (!response.ok) {
              const errorBody = await response.json();
              throw new Error(`Meta API Error: ${JSON.stringify(errorBody)}`);
            }

            await supabaseAdmin.from('client_whatsapp_queue').update({ status: 'SENT' }).eq('id', job.id);
          } catch (e) {
            await supabaseAdmin.from('client_whatsapp_queue').update({ status: 'FAILED', error_message: e.message, attempts: job.attempts + 1 }).eq('id', job.id);
          }
        }
      } catch (e) {
        console.error(`Failed to process jobs for tenant ${tenantId}: ${e.message}`);
        // Mark all jobs for this tenant as failed if we can't get credentials
        const jobIds = tenantJobs.map(j => j.id);
        await supabaseAdmin.from('client_whatsapp_queue').update({ status: 'FAILED', error_message: e.message }).in('id', jobIds);
      }
    });

    await Promise.all(processingPromises);

    return new Response(JSON.stringify({ message: `Processed ${jobs.length} jobs.` }), { headers: { "Content-Type": "application/json" } });

  } catch (error) {
    return new Response(JSON.stringify({ error: error.message }), { status: 500, headers: { 'Content-Type': 'application/json' } });
  }
});