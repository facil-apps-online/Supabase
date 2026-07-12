import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    // 1. Extract parameters from the request body
    const { fileId, integration_owner_tenant_id, platform_id } = await req.json();
    if (!fileId) {
      return new Response(JSON.stringify({ error: 'Missing required body parameters: fileId is required.' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // 2. Create Supabase admin client
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    // Determine which tenant owns the integration credentials
    let integrationTenantId = integration_owner_tenant_id;
    
    // If not provided, fetch the system owner for the platform
    if (!integrationTenantId && platform_id) {
      const { data: ownerTenant, error: ownerError } = await supabaseAdmin
        .from('tenants')
        .select('id')
        .eq('platform_id', platform_id)
        .eq('is_system_owner', true)
        .single();
        
      if (ownerError || !ownerTenant) {
        throw new Error(`Failed to find system owner tenant for platform ${platform_id}: ${ownerError?.message}`);
      }
      integrationTenantId = ownerTenant.id;
    }
    
    if (!integrationTenantId) {
      return new Response(JSON.stringify({ error: 'Missing required body parameters: integration_owner_tenant_id or platform_id is required.' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // 3. Fetch the Google Drive integration from the DB
    const { data: googleDriveIntegration, error: fetchIntegrationError } = await supabaseAdmin
      .from('tenant_integrations')
      .select('*')
      .eq('tenant_id', integrationTenantId)
      .eq('provider', 'google_drive')
      .single();

    if (fetchIntegrationError) throw new Error(`Failed to fetch Google Drive integration for tenant ${integrationTenantId}: ${fetchIntegrationError.message}`);
    if (!googleDriveIntegration.encrypted_credentials || !googleDriveIntegration.nonce) {
      throw new Error('La integración de Google Drive no tiene las credenciales encriptadas.');
    }

    // 4. Decrypt the refresh_token
    const { data: decryptedResponse, error: decryptError } = await supabaseAdmin.functions.invoke(
      'decrypt-secret',
      {
        body: { encryptedData: googleDriveIntegration.encrypted_credentials, iv: googleDriveIntegration.nonce },
        headers: {
          'Authorization': `Bearer ${Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')}`
        }
      }
    );

    if (decryptError) throw new Error(`Failed to invoke decrypt-secret function: ${decryptError.message}`);
    
    const refreshToken = decryptedResponse.decryptedText;
    if (!refreshToken) throw new Error('La respuesta de descifrado no contenía "decryptedText".');

    // 5. Use the refresh_token to get a new access_token
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
      // Don't deactivate integration on delete failure, just report the error
      throw new Error(`Google token refresh failed: ${JSON.stringify(errorBody)}`);
    }

    const tokens = await tokenResponse.json();
    const accessToken = tokens.access_token;

    // 6. Delete the file from Google Drive
    const deleteResponse = await fetch(
      `https://www.googleapis.com/drive/v3/files/${fileId}`,
      {
        method: 'DELETE',
        headers: { 'Authorization': `Bearer ${accessToken}` },
      }
    );
    
    // Google Drive returns 204 No Content on success, or 404 if file is already gone.
    // We can treat 404 as a success for our purposes.
    if (!deleteResponse.ok && deleteResponse.status !== 404) {
      const errorBody = await deleteResponse.json();
      throw new Error(`Google Drive delete failed for file ${fileId}: ${JSON.stringify(errorBody)}`);
    }

    // 7. Return success
    return new Response(JSON.stringify({ success: true, message: `File ${fileId} deleted successfully.` }), {
      status: 200,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });

  } catch (error) {
    console.error('Error in core google-drive-delete flow:', error);
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});
