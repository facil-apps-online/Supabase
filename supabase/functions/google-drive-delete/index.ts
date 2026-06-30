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
    const { fileId, tenantId, uploadContext } = await req.json(); // Add uploadContext
    if (!fileId || !tenantId) {
      return new Response(JSON.stringify({ error: 'Missing required body parameters: fileId and tenantId are required.' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // 2. Create Supabase admin client
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    let integrationTenantId = tenantId;
    // Determine the correct tenantId for the integration lookup, similar to google-drive-upload
    if (uploadContext === 'Avatars') {
      const { data: ownerId, error: rpcError } = await supabaseAdmin.rpc('get_system_owner_tenant_id');
      if (rpcError) throw new Error(`Could not get system owner tenant ID: ${rpcError.message}`);
      if (!ownerId) throw new Error('System owner tenant ID not found.');
      integrationTenantId = ownerId;
    }

    // 3. Fetch the Google Drive integration using the determined tenantId
    const { data: googleDriveIntegration, error: fetchIntegrationError } = await supabaseAdmin
      .from('tenant_integrations')
      .select('*')
      .eq('tenant_id', integrationTenantId)
      .eq('provider', 'google_drive')
      .single();

    if (fetchIntegrationError) {
        console.warn(`Could not find Google Drive integration for tenant ${integrationTenantId}. File ${fileId} may not be deleted from Drive.`);
        return new Response(JSON.stringify({ success: true, message: `Integration not found, file ${fileId} on Google Drive may not have been deleted.` }), {
            status: 200,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
    }
    if (!googleDriveIntegration.encrypted_credentials || !googleDriveIntegration.nonce) {
      console.warn(`Google Drive integration for tenant ${integrationTenantId} is missing credentials. File ${fileId} may not be deleted from Drive.`);
      return new Response(JSON.stringify({ success: true, message: `Integration credentials not found, file ${fileId} on Google Drive may not have been deleted.` }), {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
    }

    // 4. Decrypt the refresh_token
    const { data: decryptedResponse, error: decryptError } = await supabaseAdmin.functions.invoke(
      'decrypt-secret',
      { body: { encryptedData: googleDriveIntegration.encrypted_credentials, iv: googleDriveIntegration.nonce } }
    );

    if (decryptError) throw new Error(`Failed to invoke decrypt-secret function: ${decryptError.message}`);
    
    const refreshToken = decryptedResponse.decryptedText;
    if (!refreshToken) throw new Error('Decryption response did not contain "decryptedText".');

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

      if (errorBody.error === 'invalid_grant') {
        console.error(`invalid_grant error for integration ID: ${googleDriveIntegration.id}. Deactivating integration.`);
        await supabaseAdmin
          .from('tenant_integrations')
          .update({ is_active: false, updated_at: new Date().toISOString() })
          .eq('id', googleDriveIntegration.id);
        
        throw new Error('Google connection has expired. Please reconnect your account from settings.');
      }

      throw new Error(`Google token refresh failed: ${JSON.stringify(errorBody)}`);
    }

    const tokens = await tokenResponse.json();
    const accessToken = tokens.access_token;

    // 6. Delete the file from Google Drive
    const deleteResponse = await fetch(
      `https://www.googleapis.com/drive/v3/files/${fileId}`,
      {
        method: 'DELETE',
        headers: {
          'Authorization': `Bearer ${accessToken}`,
        },
      }
    );

    if (!deleteResponse.ok) {
        if (deleteResponse.status === 404) {
            console.log(`File ${fileId} not found in Google Drive. Assumed to be already deleted.`);
        } else {
            const errorBody = await deleteResponse.json();
            throw new Error(`Google Drive delete failed: ${JSON.stringify(errorBody)}`);
        }
    }

    console.log(`Successfully deleted file ${fileId} from Google Drive.`);

    // 7. Return success
    return new Response(JSON.stringify({ success: true, message: `File ${fileId} deleted successfully.` }), {
      status: 200,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });

  } catch (error) {
    console.error('Error in google-drive-delete function:', error);
    return new Response(JSON.stringify({ error: error.message }), {
      status: 200, // Return 200 to not fail the DB trigger.
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});
