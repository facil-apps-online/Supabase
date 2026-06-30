import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const GOOGLE_CLIENT_ID = Deno.env.get('GOOGLE_CLIENT_ID');
const GOOGLE_CLIENT_SECRET = Deno.env.get('GOOGLE_CLIENT_SECRET');
const REDIRECT_URI = Deno.env.get('GOOGLE_REDIRECT_URI');

// Headers de CORS para permitir peticiones desde el frontend
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

serve(async (req) => {
  // Manejar la petición preflight de CORS
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    // **VERIFICACIÓN DE VARIABLES DE ENTORNO**
    const requiredEnv = [
      'GOOGLE_CLIENT_ID', 'GOOGLE_CLIENT_SECRET', 'GOOGLE_REDIRECT_URI',
      'SUPABASE_URL', 'SUPABASE_SERVICE_ROLE_KEY'
    ];
    for (const env of requiredEnv) {
      if (!Deno.env.get(env)) {
        throw new Error(`Missing required environment variable: ${env}`);
      }
    }

    const { code, tenantId, provider } = await req.json();

    if (!code || !tenantId || !provider) {
      return new Response(JSON.stringify({ error: 'Missing code, tenantId, or provider' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }
    
    // Validar que el provider sea uno de los esperados
    if (provider !== 'google_drive' && provider !== 'google_gmail') {
      return new Response(JSON.stringify({ error: 'Invalid provider specified' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }
    
    // 1. Intercambiar código por tokens
    const tokenResponse = await fetch('https://oauth2.googleapis.com/token', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        code,
        client_id: GOOGLE_CLIENT_ID,
        client_secret: GOOGLE_CLIENT_SECRET,
        redirect_uri: REDIRECT_URI,
        grant_type: 'authorization_code',
      }),
    });

    if (!tokenResponse.ok) {
      const errorBody = await tokenResponse.json();
      throw new Error(`Google token exchange failed: ${JSON.stringify(errorBody)}`);
    }

    const tokens = await tokenResponse.json();
    const { access_token, refresh_token, id_token } = tokens;

    // 2. Obtener info del usuario
    const userInfoResponse = await fetch('https://www.googleapis.com/oauth2/v3/userinfo', {
        headers: { Authorization: `Bearer ${access_token}` },
    });
    const userInfo = await userInfoResponse.json();
    const userEmail = userInfo.email;

    // 3. Cifrar el refresh token usando la nueva Edge Function
    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const encryptResponse = await fetch(`${supabaseUrl}/functions/v1/encrypt-secret`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')}`
      },
      body: JSON.stringify({ dataToEncrypt: refresh_token }),
    });

    if (!encryptResponse.ok) {
      const errorBody = await encryptResponse.json();
      throw new Error(`Encryption failed: ${JSON.stringify(errorBody)}`);
    }
    const { encryptedData, iv } = await encryptResponse.json();

    // 4. Guardar en la base de datos
    const supabaseAdmin = createClient(
      supabaseUrl ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    const upsertData = {
      tenant_id: tenantId,
      provider: provider,
      access_token: access_token,
      encrypted_credentials: encryptedData,
      nonce: iv,
      account_email: userEmail,
      updated_at: new Date().toISOString(),
      environment: 'production', // Añadir explícitamente el entorno
    };

    const { error: dbError } = await supabaseAdmin
      .from('tenant_integrations')
      .upsert(upsertData, { onConflict: 'tenant_id, provider, environment' }); // Corregir onConflict

    if (dbError) throw dbError;

    return new Response(JSON.stringify({ success: true, message: 'Integration successful.' }), {
      status: 200,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });

  } catch (error) {
    console.error('Error in Google OAuth flow:', error);
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});
