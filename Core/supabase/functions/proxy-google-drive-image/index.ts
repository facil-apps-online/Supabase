import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { jwtDecode } from "https://esm.sh/jwt-decode@4.0.0";
import { getSupabaseAdminClient } from '../_shared/supabaseClients.ts';

serve(async (req) => {
  const requestOrigin = req.headers.get('Origin');
  console.log(`[proxy-gdrive-core] Request received from origin: ${requestOrigin}`);

  const corsHeaders: Record<string, string> = {
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'GET, OPTIONS',
  };

  // IMPORTANT: The combination of a wildcard origin ('*') and allowing credentials ('true') is not permitted by browsers.
  // We must dynamically set the origin. If no origin is present, the request will likely fail on the client-side,
  // but the server response itself is valid.
  if (requestOrigin) {
    corsHeaders['Access-Control-Allow-Origin'] = requestOrigin;
    corsHeaders['Access-Control-Allow-Credentials'] = 'true';
  } else {
    corsHeaders['Access-Control-Allow-Origin'] = '*';
  }
  
  console.log(`[proxy-gdrive-core] Responding with CORS headers: ${JSON.stringify(corsHeaders)}`);

  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const url = new URL(req.url);
    const fileId = url.searchParams.get('fileId');

    console.log(`[proxy-gdrive-core] Processing fileId: ${fileId}`);

    if (!fileId) {
      return new Response(JSON.stringify({ error: 'Falta el parámetro fileId' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    const tenantId = url.searchParams.get('tenantId'); // Required
    const platformId = url.searchParams.get('platformId'); // Required

    if (!tenantId || !platformId) {
      return new Response(JSON.stringify({ error: 'Faltan los parámetros requeridos: tenantId y platformId.' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    const coreSupabase = getSupabaseAdminClient();
    let integrationTenantId;
    
    // Fetch the system owner for the platform
    const { data: ownerTenant, error: ownerError } = await coreSupabase
      .from('tenants')
      .select('id')
      .eq('platform_id', platformId)
      .eq('is_system_owner', true)
      .single();
      
    if (ownerError || !ownerTenant) {
      throw new Error(`Failed to find system owner tenant for platform ${platformId}: ${ownerError?.message}`);
    }
    integrationTenantId = ownerTenant.id;
    
    console.log(`[proxy-gdrive-core] Using system owner tenantId: ${integrationTenantId} for platformId: ${platformId} (Requested by tenant: ${tenantId})`);
    
    const { data: googleDriveIntegration, error: fetchIntegrationError } = await coreSupabase
      .from('tenant_integrations')
      .select('encrypted_credentials, nonce')
      .eq('tenant_id', integrationTenantId)
      .eq('provider', 'google_drive')
      .single();

    if (fetchIntegrationError) {
      console.error(`[proxy-gdrive-core] Error fetching integration for tenant ${integrationTenantId}:`, fetchIntegrationError.message);
      throw new Error(`Failed to fetch Google Drive integration for tenant ${integrationTenantId}: ${fetchIntegrationError.message}`);
    }
    if (!googleDriveIntegration || !googleDriveIntegration.encrypted_credentials || !googleDriveIntegration.nonce) {
      console.error(`[proxy-gdrive-core] Incomplete Google Drive integration data for tenant ${integrationTenantId}`);
      throw new Error('La integración de Google Drive no tiene las credenciales encriptadas o no fue encontrada.');
    }
    console.log(`[proxy-gdrive-core] Found Google Drive integration for tenant ${integrationTenantId}`);

    const { data: decryptedResponse, error: decryptError } = await coreSupabase.functions.invoke(
      'decrypt-secret', { body: { encryptedData: googleDriveIntegration.encrypted_credentials, iv: googleDriveIntegration.nonce } }
    );

    if (decryptError) {
      console.error(`[proxy-gdrive-core] Decrypt function invocation failed:`, decryptError.message);
      throw new Error(`Failed to invoke decrypt-secret function: ${decryptError.message}`);
    }
    const refreshToken = decryptedResponse.decryptedText;
    if (!refreshToken) throw new Error('La respuesta de descifrado no contenía "decryptedText".');
    console.log(`[proxy-gdrive-core] Successfully decrypted refresh token.`);

    const tokenResponse = await fetch('https://oauth2.googleapis.com/token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        client_id: Deno.env.get('GOOGLE_CLIENT_ID'),
        client_secret: Deno.env.get('GOOGLE_CLIENT_SECRET'),
        refresh_token: refreshToken,
        grant_type: 'refresh_token',
      }),
    });

    if (!tokenResponse.ok) {
      const errorBody = await tokenResponse.json();
      console.error(`[proxy-gdrive-core] Google token refresh failed. Response:`, errorBody);
      throw new Error(`Google token refresh failed: ${JSON.stringify(errorBody)}`);
    }
    const tokens = await tokenResponse.json();
    const accessToken = tokens.access_token;
    console.log(`[proxy-gdrive-core] Successfully obtained Google access token.`);

    const googleDriveUrl = `https://www.googleapis.com/drive/v3/files/${fileId}?alt=media`;
    console.log(`[proxy-gdrive-core] Fetching file from Google Drive: ${googleDriveUrl}`);
    const response = await fetch(googleDriveUrl, { headers: { 'Authorization': `Bearer ${accessToken}` } });

    console.log(`[proxy-gdrive-core] Google Drive response status: ${response.status}`);
    if (!response.ok) {
      return new Response(response.body, {
        status: response.status,
        statusText: response.statusText,
        headers: { ...corsHeaders },
      });
    }

    const imageBody = response.body;
    const headers = new Headers(corsHeaders);
    const contentType = response.headers.get('content-type');
    
    if (contentType && (contentType.startsWith('image/') || contentType === 'application/pdf' || contentType.includes('document') || contentType.includes('pdf'))) {
      headers.set('content-type', contentType);
    } else {
      // Just set whatever it is instead of throwing, or explicitly allow all.
      // But let's allow it if it's a known safe type. Actually, since we control the platform, we can just allow the contentType through.
      headers.set('content-type', contentType || 'application/octet-stream');
    }

    headers.set('Cache-Control', 'public, max-age=31536000, immutable');
    console.log('[proxy-gdrive-core] Successfully processed and returning image.');
    return new Response(imageBody, { status: 200, headers: headers });

  } catch (error) {
    console.error('[proxy-gdrive-core] Top-level error:', error);
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});