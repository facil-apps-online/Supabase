
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';

// --- Environment Variables ---
const SUPABASE_URL = Deno.env.get('SUPABASE_URL');
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
const ENCRYPTION_KEY = Deno.env.get('FAO_ENCRYPTION_KEY');

// --- Encryption Helpers (copied from process-whatsapp-queue) ---
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

// --- Platform Secrets Helper (Database-driven) ---
const secretsCache = new Map<string, { secrets: any; timestamp: number }>();

async function getSecretsFromDatabase(supabaseAdmin: any, platformId: string): Promise<{ verifyToken: string; appSecret: string }> {
  const now = Date.now();

  // 1. Check cache first
  const cached = secretsCache.get(platformId);
  if (cached && (now - cached.timestamp < 300000)) { // 5 minute cache
    return cached.secrets;
  }

  // 2. Find owner tenant for the platform
  const { data: ownerTenant, error: ownerError } = await supabaseAdmin
    .from('tenants')
    .select('id')
    .eq('platform_id', platformId)
    .eq('is_system_owner', true)
    .single();

  if (ownerError || !ownerTenant) {
    throw new Error(`Could not find system owner for platform_id: ${platformId}`);
  }

  // 3. Get integration for the owner tenant
  const { data: integration, error: integrationError } = await supabaseAdmin
    .from('tenant_integrations')
    .select('encrypted_credentials, nonce')
    .eq('tenant_id', ownerTenant.id)
    .eq('provider', 'meta_whatsapp')
    .eq('is_active', true)
    .single();

  if (integrationError || !integration) {
    throw new Error(`No active WhatsApp integration found for owner of platform ${platformId}.`);
  }

  // 4. Decrypt credentials and extract secrets
  const credentials = await decrypt(integration.encrypted_credentials, integration.nonce);
  const { app_secret: appSecret, verify_token: verifyToken } = credentials;

  if (!appSecret || !verifyToken) {
      throw new Error(`'app_secret' or 'verify_token' not found in decrypted credentials for platform ${platformId}.`);
  }

  const secrets = { verifyToken, appSecret };

  // 5. Cache and return
  secretsCache.set(platformId, { secrets, timestamp: now });
  return secrets;
}


// --- Main Handler ---
serve(async (req) => {
  const url = new URL(req.url);
  const supabaseAdmin = createClient(SUPABASE_URL ?? '', SUPABASE_SERVICE_ROLE_KEY ?? '');

  try {
    const platformId = url.searchParams.get('platform_id');
    if (!platformId) {
      throw new Error("Missing 'platform_id' query parameter in webhook URL.");
    }
    
    const { verifyToken, appSecret } = await getSecretsFromDatabase(supabaseAdmin, platformId);

    // --- 1. Handle Webhook Verification (GET Request) ---
    if (req.method === 'GET') {
      const mode = url.searchParams.get('hub.mode');
      const token = url.searchParams.get('hub.verify_token');
      const challenge = url.searchParams.get('hub.challenge');

      if (mode === 'subscribe' && token === verifyToken) {
        console.log(`Webhook for platform '${platformId}' verified successfully!`);
        return new Response(challenge, { status: 200 });
      } else {
        console.error(`Webhook verification failed for platform ${platformId}.`);
        return new Response('Forbidden', { status: 403 });
      }
    }

    // --- 2. Handle Incoming Messages (POST Request) ---
    if (req.method === 'POST') {
      // --- 2a. Security Validation ---
      const signature = req.headers.get('X-Hub-Signature-256');
      if (!signature) {
        throw new Error('Missing X-Hub-Signature-256 header');
      }

      const body = await req.text();
      const hmac = await crypto.subtle.importKey('raw', new TextEncoder().encode(appSecret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
      const digest = await crypto.subtle.sign('HMAC', hmac, new TextEncoder().encode(body));
      const calculatedSignature = `sha256=${Array.from(new Uint8Array(digest)).map(b => b.toString(16).padStart(2, '0')).join('')}`;

      if (calculatedSignature !== signature) {
        throw new Error('Signature validation failed');
      }

      // --- 2b. Acknowledge receipt immediately ---
      setTimeout(async () => {
        try {
          const payload = JSON.parse(body);
          if (payload.object === 'whatsapp_business_account') {
            for (const entry of payload.entry) {
              for (const change of entry.changes) {
                if (change.field === 'messages') {
                  for (const message of change.value.messages) {
                    await processMessage(message, supabaseAdmin);
                  }
                }
              }
            }
          }
        } catch (e) {
          console.error('Error processing message payload:', e);
        }
      }, 0);

      return new Response('OK', { status: 200 });
    }

    // Handle other methods
    return new Response('Method Not Allowed', { status: 405 });

  } catch (error) {
    console.error('Error in webhook:', error.message);
    return new Response(JSON.stringify({ error: error.message }), { status: 500, headers: { 'Content-Type': 'application/json' } });
  }
});

// --- 3. Message Processing Logic (Unchanged) ---
async function processMessage(message: any, supabase: any) {
  console.log('Processing message:', JSON.stringify(message));

  if (message.type === 'interactive' && message.interactive?.type === 'button_reply') {
    const buttonId = message.interactive.button_reply.id;
    const [action, token] = buttonId.split('_');

    if ((action === 'confirm' || action === 'cancel') && token) {
      console.log(`Action: ${action}, Token: ${token}`);
      const updateUrl = `${SUPABASE_URL}/functions/v1/update-attention-status?token=${token}&action=${action}`;
      const response = await fetch(updateUrl);
      if (!response.ok) {
        console.error(`Failed to update attention status for token ${token}. Status: ${response.status}`);
      }
    }
    return;
  }

  if (message.type === 'text') {
    const clientPhone = message.from;

    const { data: client, error: clientError } = await supabase
      .from('clients')
      .select('id, tenant_id')
      .eq('phone', clientPhone)
      .single();

    if (clientError || !client) {
      console.warn(`Client not found for phone number: ${clientPhone}`);
      return;
    }

    const { data: attentions, error: attentionsError } = await supabase
      .from('attentions')
      .select('attention_datetime')
      .eq('client_id', client.id)
      .in('status', ['Pendiente', 'Confirmada'])
      .gte('attention_datetime', new Date().toISOString())
      .order('attention_datetime', { ascending: true })
      .limit(5);

    if (attentionsError) {
      console.error(`Error fetching attentions for client ${client.id}:`, attentionsError);
      return;
    }

    let replyBody = '';
    if (!attentions || attentions.length === 0) {
      replyBody = 'Hola! No hemos encontrado citas próximas para este número.';
    } else {
      const formattedDates = attentions.map(att => 
        `- ${new Date(att.attention_datetime).toLocaleString('es-ES', { weekday: 'long', year: 'numeric', month: 'long', day: 'numeric', hour: '2-digit', minute: '2-digit' })}`
      ).join('\n');
      replyBody = `Hola! Tus próximas citas son:\n${formattedDates}`;
    }

    await supabase.rpc('queue_client_whatsapp', {
      p_tenant_id: client.tenant_id,
      p_client_id: client.id,
      p_template_name: 'generic_text_message',
      p_template_params: {
        parameters: [{ type: 'text', text: replyBody }]
      }
    });
  }
}
