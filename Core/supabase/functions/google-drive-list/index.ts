import { corsHeaders } from '../_shared/cors.ts';
import { getSupabaseAdminClient } from '../_shared/supabaseClients.ts';

/**
 * Lists .repx files in the templates folder of the platform's system_owner
 * Google Drive. Facil Reports (server-to-server) calls this with the platformId.
 *
 * Requires header `X-Service-Secret` matching env FAO_REPORTING_SERVICE_SECRET.
 * POST { "platformId": "..." }
 * Returns { files: [{ id, name, createdTime, modifiedTime }] }.
 */
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const expectedSecret = Deno.env.get('FAO_REPORTING_SERVICE_SECRET');
    const providedSecret = req.headers.get('X-Service-Secret');

    if (!expectedSecret || providedSecret !== expectedSecret) {
      return new Response(
        JSON.stringify({ error: 'Unauthorized' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 401 }
      );
    }

    const { platformId } = await req.json();
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
        JSON.stringify({ files: [] }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 200 }
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
    if (!integration || !integration.encrypted_credentials || !integration.nonce) {
      return new Response(
        JSON.stringify({ files: [] }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 200 }
      );
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

    if (!tokenResponse.ok) throw new Error('Google token refresh failed.');

    const tokens = await tokenResponse.json();
    const accessToken = tokens.access_token;

    // 5. Find the "templates" folder for the platform and list its files
    const folderQuery = `mimeType = 'application/vnd.google-apps.folder' and name = 'templates' and 'root' in parents and trashed = false`;
    const folderResponse = await fetch(
      `https://www.googleapis.com/drive/v3/files?q=${encodeURIComponent(folderQuery)}&fields=files(id,name)`,
      { headers: { 'Authorization': `Bearer ${accessToken}` } }
    );

    if (!folderResponse.ok) {
      return new Response(
        JSON.stringify({ files: [] }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 200 }
      );
    }

    const folderResult = await folderResponse.json();
    if (folderResult.files.length === 0) {
      return new Response(
        JSON.stringify({ files: [] }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 200 }
      );
    }

    const templatesFolderId = folderResult.files[0].id;

    const filesQuery = `'${templatesFolderId}' in parents and trashed = false`;
    const filesResponse = await fetch(
      `https://www.googleapis.com/drive/v3/files?q=${encodeURIComponent(filesQuery)}&fields=files(id,name,createdTime,modifiedTime)&orderBy=name`,
      { headers: { 'Authorization': `Bearer ${accessToken}` } }
    );

    if (!filesResponse.ok) {
      return new Response(
        JSON.stringify({ files: [] }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 200 }
      );
    }

    const filesResult = await filesResponse.json();

    return new Response(
      JSON.stringify({ files: filesResult.files ?? [] }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 200 }
    );
  } catch (err) {
    return new Response(
      JSON.stringify({ error: err instanceof Error ? err.message : 'Internal error' }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 500 }
    );
  }
});
