import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*', 
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

// Helper function to find or create a folder in Google Drive
async function findOrCreateFolder(
  folderName: string,
  parentFolderId: string | null,
  accessToken: string
): Promise<string> {
  // Clean folder name to avoid issues with special characters in GDrive query
  const cleanedFolderName = folderName.replace(/'/g, "\'");
  const q = `name = '${cleanedFolderName}' and mimeType = 'application/vnd.google-apps.folder' and trashed = false`;
  const parentQuery = parentFolderId ? ` and '${parentFolderId}' in parents` : " and 'root' in parents";
  const finalQuery = q + parentQuery;

  const searchResponse = await fetch(
    `https://www.googleapis.com/drive/v3/files?q=${encodeURIComponent(finalQuery)}&fields=files(id)`,
    {
      method: 'GET',
      headers: { 'Authorization': `Bearer ${accessToken}` },
    }
  );
  if (!searchResponse.ok) {
    const errorBody = await searchResponse.json();
    throw new Error(`Failed to search for folder ${folderName}: ${JSON.stringify(errorBody)}`);
  }
  const searchResult = await searchResponse.json();
  if (searchResult.files.length > 0) {
    return searchResult.files[0].id;
  }

  // If not found, create it
  const createMetadata = {
    name: folderName,
    mimeType: 'application/vnd.google-apps.folder',
    parents: parentFolderId ? [parentFolderId] : [],
  };
  const createResponse = await fetch(
    `https://www.googleapis.com/drive/v3/files`,
    {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${accessToken}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(createMetadata),
    }
  );
  if (!createResponse.ok) {
    const errorBody = await createResponse.json();
    throw new Error(`Failed to create folder ${folderName}: ${JSON.stringify(errorBody)}`);
  }
  const createdFolder = await createResponse.json();
  return createdFolder.id;
}


serve(async (req) => {
  console.log('[gdrive-upload] Function invoked.');
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    // 1. Extract parameters from the request body (refactored)
    const payload = await req.json();
    console.log('[gdrive-upload] Received payload:', payload);
    const { platform_id, fileBase64, mimeType, fileName, path_components, integration_owner_tenant_id, tenantId } = payload;
    if (!platform_id || !fileBase64 || !mimeType || !fileName || !path_components || !Array.isArray(path_components)) {
      return new Response(JSON.stringify({ error: 'Missing required body parameters: platform_id, fileBase64, mimeType, fileName, and path_components (array) are required.' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // 2. Create Supabase admin client
    console.log('[gdrive-upload] Creating Supabase admin client...');
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );
    console.log('[gdrive-upload] Supabase admin client created.');

    // 3. Get platform name from platform_id (for root folder)
    console.log(`[gdrive-upload] Fetching platform data for platform_id: ${platform_id}`);
    const { data: platformData, error: platformError } = await supabaseAdmin
      .from('platforms')
      .select('name')
      .eq('id', platform_id)
      .single();

    if (platformError) throw new Error(`Failed to fetch platform name: ${platformError.message}`);
    if (!platformData) throw new Error(`Platform with id ${platform_id} not found.`);
    
    const platformName = platformData.name;
    console.log(`[gdrive-upload] Found platformName: ${platformName}`);

    // 4. Determine which tenant owns the integration credentials
    let integrationTenantId = integration_owner_tenant_id;
    
    // If not provided, fetch the system owner for the platform
    if (!integrationTenantId) {
      console.log(`[gdrive-upload] No integration_owner_tenant_id provided, fetching system owner for platform ${platform_id}`);
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
    
    console.log(`[gdrive-upload] Using integrationTenantId: ${integrationTenantId}`);

    // 5. Fetch the Google Drive integration from the DB
    console.log(`[gdrive-upload] Fetching Google Drive integration for tenant: ${integrationTenantId}`);
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
    console.log(`[gdrive-upload] Successfully fetched integration ID: ${googleDriveIntegration.id}`);

    // 6. Decrypt the refresh_token
    console.log('[gdrive-upload] PRE-INVOKE: About to invoke decrypt-secret function...');
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
    console.log('[gdrive-upload] POST-INVOKE: decrypt-secret function invoked successfully.');
    
    const refreshToken = decryptedResponse.decryptedText;
    if (!refreshToken) throw new Error('La respuesta de descifrado no contenía "decryptedText".');

    // 7. Use the refresh_token to get a new access_token
    console.log('[gdrive-upload] Refreshing Google token...');
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
        await supabaseAdmin
          .from('tenant_integrations')
          .update({ is_active: false, updated_at: new Date().toISOString() })
          .eq('id', googleDriveIntegration.id);
        throw new Error('La conexión con Google ha expirado. Por favor, vuelve a conectar tu cuenta desde la configuración.');
      }
      throw new Error(`Google token refresh failed: ${JSON.stringify(errorBody)}`);
    }

    const tokens = await tokenResponse.json();
    const accessToken = tokens.access_token;
    console.log('[gdrive-upload] Google token refreshed.');

    // 8. Create dynamic folder structure from path_components (refactored)
    console.log('[gdrive-upload] Creating folder structure...');
    let parentFolderId = null;
    
    // Inject the tenantId as the first subfolder to isolate tenant files
    if (tenantId) {
      parentFolderId = await findOrCreateFolder(tenantId, parentFolderId, accessToken);
    }
    
    for (const folderName of path_components) {
        if (folderName) { // Avoid creating folders for empty/null path components
            parentFolderId = await findOrCreateFolder(folderName, parentFolderId, accessToken);
        }
    }
    const finalFolderId = parentFolderId;
    console.log(`[gdrive-upload] Final folder ID: ${finalFolderId}`);


    // 9. Calculate file size and upload to Google Drive
    console.log('[gdrive-upload] Preparing file for upload...');
    const fileBuffer = Uint8Array.from(atob(fileBase64), c => c.charCodeAt(0));
    const fileSize = fileBuffer.length; // Calculate file size in bytes
    const boundary = '----------CoreFileUploadBoundary';
    const now = new Date();
    const timestamp = `${now.getFullYear()}${(now.getMonth() + 1).toString().padStart(2, '0')}${now.getDate().toString().padStart(2, '0')}_${now.getHours().toString().padStart(2, '0')}${now.getMinutes().toString().padStart(2, '0')}${now.getSeconds().toString().padStart(2, '0')}`;
    const newFileName = `${timestamp}_${fileName}`;

    const metadata = { name: newFileName, mimeType, parents: [finalFolderId] };
    const encoder = new TextEncoder();
    const metadataPart = encoder.encode(`--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n${JSON.stringify(metadata)}\r\n`);
    const mediaPart = encoder.encode(`--${boundary}\r\nContent-Type: ${mimeType}\r\n\r\n`);
    const endPart = encoder.encode(`\r\n--${boundary}--\r\n`);
    const totalLength = metadataPart.length + mediaPart.length + fileBuffer.length + endPart.length;
    const requestBody = new Uint8Array(totalLength);
    let offset = 0;
    requestBody.set(metadataPart, offset);
    offset += metadataPart.length;
    requestBody.set(mediaPart, offset);
    offset += mediaPart.length;
    requestBody.set(fileBuffer, offset);
    offset += fileBuffer.length;
    requestBody.set(endPart, offset);

    console.log('[gdrive-upload] Uploading to Google Drive...');
    const uploadResponse = await fetch(
      `https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart`,
      {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${accessToken}`,
          'Content-Type': `multipart/related; boundary=${boundary}`,
        },
        body: requestBody,
      }
    );

    if (!uploadResponse.ok) {
      const errorBody = await uploadResponse.json();
      throw new Error(`Google Drive upload failed: ${JSON.stringify(errorBody)}`);
    }

    const driveFile = await uploadResponse.json();
    const fileId = driveFile.id;
    console.log(`[gdrive-upload] File uploaded successfully. File ID: ${fileId}`);

    // 10. Make the file public
    await fetch(
      `https://www.googleapis.com/drive/v3/files/${fileId}/permissions`,
      {
        method: 'POST',
        headers: { 'Authorization': `Bearer ${accessToken}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ role: 'reader', type: 'anyone' }),
      }
    );

    // 11. Return all relevant file metadata. The client is responsible for DB updates.
    console.log('[gdrive-upload] Returning success response.');
    return new Response(JSON.stringify({ 
      success: true, 
      fileId: fileId,
      fileName: newFileName,
      fileSize: fileSize,
      mimeType: mimeType
    }), {
      status: 200,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });

  } catch (error) {
    console.error('Error in core google-drive-upload flow:', error);
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});
