import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const GOOGLE_CLIENT_ID = Deno.env.get('GOOGLE_CLIENT_ID');
const GOOGLE_CLIENT_SECRET = Deno.env.get('GOOGLE_CLIENT_SECRET');
const REDIRECT_URI = Deno.env.get('GOOGLE_REDIRECT_URI'); // Aunque no se usa directamente para refrescar, es buena práctica tenerla

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const requiredEnv = [
      'GOOGLE_CLIENT_ID', 'GOOGLE_CLIENT_SECRET', 'SUPABASE_URL', 'SUPABASE_SERVICE_ROLE_KEY'
    ];
    for (const env of requiredEnv) {
      if (!Deno.env.get(env)) {
        throw new Error(`Missing required environment variable: ${env}`);
      }
    }

    const { tenantId } = await req.json();

    if (!tenantId) {
      return new Response(JSON.stringify({ error: 'Missing tenantId' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    // 1. Obtener las credenciales encriptadas de la base de datos
    const { data: integration, error: fetchError } = await supabaseAdmin
      .from('tenant_integrations')
      .select('encrypted_credentials, nonce')
      .eq('tenant_id', tenantId)
      .eq('provider', 'google_drive')
      .single();

    if (fetchError || !integration) {
      throw new Error(`Integration not found or error fetching: ${fetchError?.message || 'No data'}`);
    }

    if (!integration.encrypted_credentials || !integration.nonce) {
      throw new Error('La integración no tiene credenciales encriptadas o nonce.');
    }

    // 2. Desencriptar el refresh_token usando la Edge Function
    const { data: decryptedResponse, error: decryptError } = await supabaseAdmin.functions.invoke(
      'decrypt-secret',
      {
        body: {
          encryptedData: integration.encrypted_credentials,
          iv: integration.nonce,
        },
      }
    );

    if (decryptError) {
      throw new Error(`Failed to invoke decrypt-secret function: ${decryptError.message}`);
    }

    // La respuesta de la función es un JSON con la clave 'decryptedText'
    const credentialsJson = decryptedResponse.decryptedText;
    if (!credentialsJson) {
      throw new Error('La respuesta de descifrado no contenía "decryptedText".');
    }
    
    const credentials = JSON.parse(credentialsJson);
    const refreshToken = credentials.refresh_token;

    if (!refreshToken) {
      throw new Error("El campo 'refresh_token' no se encontró en las credenciales descifradas.");
    }

    // 3. Usar el refresh_token para obtener un nuevo access_token
    const tokenResponse = await fetch('https://oauth2.googleapis.com/token', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        client_id: GOOGLE_CLIENT_ID,
        client_secret: GOOGLE_CLIENT_SECRET,
        refresh_token: refreshToken,
        grant_type: 'refresh_token',
      }),
    });

    if (!tokenResponse.ok) {
      const errorBody = await tokenResponse.json();
      throw new Error(`Google token refresh failed: ${JSON.stringify(errorBody)}`);
    }

    const tokens = await tokenResponse.json();
    const { access_token } = tokens;

    return new Response(JSON.stringify({ success: true, access_token }), {
      status: 200,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });

  } catch (error) {
    console.error('Error in Google Drive refresh token flow:', error);
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});
