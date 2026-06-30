import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { jwtDecode } from "https://esm.sh/jwt-decode@4.0.0";
import { getCoreSupabaseClient } from '../_shared/supabaseClients.ts';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const url = new URL(req.url);
    const fileId = url.searchParams.get('fileId');
    const platformId = url.searchParams.get('platformId');
    const slug = url.searchParams.get('slug');
    const countryIso = url.searchParams.get('countryIso');

    console.log(`[proxy-gdrive] Processing fileId: ${fileId}`);

    if (!fileId) {
      return new Response(JSON.stringify({ error: 'Falta el parámetro fileId' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    let tenantIdToUse: string | null = null;

    const authHeader = req.headers.get('Authorization');
    if (authHeader) {
      const token = authHeader.replace('Bearer ', '');
      const decodedToken: any = jwtDecode(token);
      tenantIdToUse = decodedToken.app_metadata?.assignments?.[0]?.tenant_id;
      if (!tenantIdToUse) throw new Error('Tenant ID not found in JWT.');
      console.log(`[proxy-gdrive] Authenticated request. Tenant ID from JWT: ${tenantIdToUse}`);
    } else {
      console.log('[proxy-gdrive] Public request. Looking for tenant via slug/platform.');
      if (!platformId || !slug || !countryIso) {
        return new Response(JSON.stringify({ error: 'Missing required parameters for public access: platformId, slug, countryIso.' }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      const coreSupabase = getCoreSupabaseClient();
      
      const { data: countryData, error: countryError } = await coreSupabase.from('countries').select('id').eq('iso_code', countryIso).single();
      if (countryError) throw new Error(`Error fetching country: ${countryError.message}`);
      if (!countryData) return new Response(JSON.stringify({ error: 'Country not found.' }), { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
      
      const { data: tenant, error: tenantError } = await coreSupabase.from('tenants').select('id').eq('platform_id', platformId).eq('slug', slug).eq('country_id', countryData.id).single();
      if (tenantError) throw new Error(`Error fetching tenant: ${tenantError.message}`);
      if (!tenant) return new Response(JSON.stringify({ error: 'Tenant not found.' }), { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });

      tenantIdToUse = tenant.id;
      console.log(`[proxy-gdrive] Public request. Found tenantId: ${tenantIdToUse}`);
    }

    if (!tenantIdToUse) {
      throw new Error("Could not determine which tenant's credentials to use.");
    }
    
    const coreSupabaseAdmin = getCoreSupabaseClient();
    const { data: googleDriveIntegration, error: fetchIntegrationError } = await coreSupabaseAdmin
      .from('tenant_integrations')
      .select('encrypted_credentials, nonce')
      .eq('tenant_id', tenantIdToUse)
      .eq('provider', 'google_drive')
      .single();

    if (fetchIntegrationError) {
      console.error(`[proxy-gdrive] Error fetching integration for tenant ${tenantIdToUse}:`, fetchIntegrationError.message);
      throw new Error(`Failed to fetch Google Drive integration for tenant ${tenantIdToUse}: ${fetchIntegrationError.message}`);
    }
    if (!googleDriveIntegration || !googleDriveIntegration.encrypted_credentials || !googleDriveIntegration.nonce) {
      console.error(`[proxy-gdrive] Incomplete Google Drive integration data for tenant ${tenantIdToUse}`);
      throw new Error('La integración de Google Drive no tiene las credenciales encriptadas o no fue encontrada.');
    }
    console.log(`[proxy-gdrive] Found Google Drive integration for tenant ${tenantIdToUse}`);

    const supabaseAdmin = createClient(Deno.env.get('SUPABASE_URL') ?? '', Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '');
    const { data: decryptedResponse, error: decryptError } = await supabaseAdmin.functions.invoke(
      'decrypt-secret', { body: { encryptedData: googleDriveIntegration.encrypted_credentials, iv: googleDriveIntegration.nonce } }
    );

    if (decryptError) {
      console.error(`[proxy-gdrive] Decrypt function invocation failed:`, decryptError.message);
      throw new Error(`Failed to invoke decrypt-secret function: ${decryptError.message}`);
    }
    const refreshToken = decryptedResponse.decryptedText;
    if (!refreshToken) throw new Error('La respuesta de descifrado no contenía "decryptedText".');
    console.log(`[proxy-gdrive] Successfully decrypted refresh token.`);

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
      console.error(`[proxy-gdrive] Google token refresh failed. Response:`, errorBody);
      throw new Error(`Google token refresh failed: ${JSON.stringify(errorBody)}`);
    }
    const tokens = await tokenResponse.json();
    const accessToken = tokens.access_token;
    console.log(`[proxy-gdrive] Successfully obtained Google access token.`);

    const googleDriveUrl = `https://www.googleapis.com/drive/v3/files/${fileId}?alt=media`;
    console.log(`[proxy-gdrive] Fetching file from Google Drive: ${googleDriveUrl}`);
    const response = await fetch(googleDriveUrl, { headers: { 'Authorization': `Bearer ${accessToken}` } });

    console.log(`[proxy-gdrive] Google Drive response status: ${response.status}`);
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
    
    if (contentType && contentType.startsWith('image/')) {
      headers.set('content-type', contentType);
    } else {
      return new Response(JSON.stringify({ error: 'El archivo obtenido de Google Drive no es una imagen o tiene un tipo de contenido inesperado.' }), {
        status: 502,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    headers.set('Cache-Control', 'public, max-age=31536000, immutable');
    console.log('[proxy-gdrive] Successfully processed and returning image.');
    return new Response(imageBody, { status: 200, headers: headers });

  } catch (error) {
    console.error('[proxy-gdrive] Top-level error:', error);
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});