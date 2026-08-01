import { corsHeaders } from '../_shared/cors.ts';
import { getSupabaseAdminClient } from '../_shared/supabaseClients.ts';

/**
 * Downloads a file from the platform's system_owner Google Drive by fileId.
 * Facil Reports (server-to-server) calls this with a Drive fileId and the
 * platformId to fetch a .repx template without exposing Drive credentials.
 *
 * Requires header `X-Service-Secret` matching env FAO_REPORTING_SERVICE_SECRET.
 * POST { "fileId": "...", "platformId": "..." }
 * Returns { fileId, fileName, mimeType, fileBase64 }.
 */
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    // Protect the endpoint: only Facil Reports server should call this.
    const expectedSecret = Deno.env.get('FAO_REPORTING_SERVICE_SECRET');
    const providedSecret = req.headers.get('X-Service-Secret');

    if (!expectedSecret || providedSecret !== expectedSecret) {
      return new Response(
        JSON.stringify({ error: 'Unauthorized' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 401 }
      );
    }

    const { fileId, platformId } = await req.json();
    if (!fileId || typeof fileId !== 'string') {
      return new Response(
        JSON.stringify({ error: 'fileId is required' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400 }
      );
    }
    if (!platformId || typeof platformId !== 'string') {
      return new Response(
        JSON.stringify({ error: 'platformId is required' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400 }
      );
    }

    const supabase = getSupabaseAdminClient();

    // 1. Find the system_owner tenant for the platform
    const { data: ownerTenant, error: ownerError } = await supabase
      .from('tenants')
      .select('id')
      .eq('platform_id', platformId)
      .eq('is_system_owner', true)
      .maybeSingle();

    if (ownerError) throw ownerError;
    if (!ownerTenant) {
      return new Response(
        JSON.stringify({ error: `No system owner tenant found for platform ${platformId}` }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 404 }
      );
    }

    // 2. Fetch the Google Drive integration for the system owner
    const { data: integration, error: integrationError } = await supabase
      .from('tenant_integrations')
      .select('id, encrypted_credentials, nonce, is_active')
      .eq('tenant_id', ownerTenant.id)
      .eq('provider', 'google_drive')
      .eq('is_active', true)
      .maybeSingle();

    if (integrationError) throw integrationError;
    if (!integration) {
      return new Response(
        JSON.stringify({ error: 'No active Google Drive integration for this platform' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 404 }
      );
    }
    if (!integration.encrypted_credentials || !integration.nonce) {
      throw new Error('Google Drive integration has no encrypted credentials.');
    }

    // 3. Decrypt the refresh_token
    const { data: decryptedResponse, error: decryptError } = await supabase.functions.invoke(
      'decrypt-secret',
      {
        body: {
          encryptedData: integration.encrypted_credentials,
          iv: integration.nonce,
        },
        headers: {
          'Authorization': `Bearer ${Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')}`,
        },
      }
    );

    if (decryptError) throw decryptError;
    const refreshToken = decryptedResponse?.decryptedText;
    if (!refreshToken) throw new Error('Failed to decrypt Google Drive credentials.');

    // 4. Refresh the Google access token
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
      if (errorBody.error === 'invalid_grant') {
        await supabase
          .from('tenant_integrations')
          .update({ is_active: false, updated_at: new Date().toISOString() })
          .eq('id', integration.id);
        throw new Error('Google connection expired. Please reconnect from settings.');
      }
      throw new Error(`Google token refresh failed: ${JSON.stringify(errorBody)}`);
    }

    const tokens = await tokenResponse.json();
    const accessToken = tokens.access_token;

    // 5. Fetch file metadata
    const metaResponse = await fetch(
      `https://www.googleapis.com/drive/v3/files/${fileId}?fields=name,mimeType`,
      { headers: { 'Authorization': `Bearer ${accessToken}` } }
    );

    if (!metaResponse.ok) {
      throw new Error(`Failed to fetch file metadata: ${metaResponse.status}`);
    }

    const meta = await metaResponse.json();

    // 6. Download the file content (alt=media)
    const downloadResponse = await fetch(
      `https://www.googleapis.com/drive/v3/files/${fileId}?alt=media`,
      { headers: { 'Authorization': `Bearer ${accessToken}` } }
    );

    if (!downloadResponse.ok) {
      throw new Error(`Failed to download file: ${downloadResponse.status}`);
    }

    const fileBuffer = await downloadResponse.arrayBuffer();
    const bytes = new Uint8Array(fileBuffer);
    let binary = '';
    for (const byte of bytes) {
      binary += String.fromCharCode(byte);
    }
    const fileBase64 = btoa(binary);

    return new Response(
      JSON.stringify({
        success: true,
        fileId,
        fileName: meta.name ?? '',
        mimeType: meta.mimeType ?? 'application/octet-stream',
        fileBase64,
        size: fileBuffer.byteLength,
      }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 200 }
    );
  } catch (err) {
    return new Response(
      JSON.stringify({ error: err instanceof Error ? err.message : 'Internal error' }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 500 }
    );
  }
});
