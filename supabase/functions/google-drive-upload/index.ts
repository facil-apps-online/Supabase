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
  const q = `name = '${folderName}' and mimeType = 'application/vnd.google-apps.folder' and trashed = false`;
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

// Helper function to delete a file from Google Drive
async function deleteFileFromGoogleDrive(
  fileId: string,
  accessToken: string
): Promise<void> {
  try {
    const deleteResponse = await fetch(
      `https://www.googleapis.com/drive/v3/files/${fileId}`,
      {
        method: 'DELETE',
        headers: { 'Authorization': `Bearer ${accessToken}` },
      }
    );
    if (!deleteResponse.ok) {
      const errorBody = await deleteResponse.json();
      console.error(`Failed to delete file ${fileId} from Google Drive: ${JSON.stringify(errorBody)}`);
      // Do not re-throw here, as the primary error (DB insert failure) is more important
    } else {
      console.log(`Successfully deleted file ${fileId} from Google Drive.`);
    }
  } catch (e) {
    console.error(`Exception while deleting file ${fileId} from Google Drive:`, e);
  }
}


serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  let accessToken: string | undefined; // Declared at a higher scope
  let fileId: string | undefined;      // Declared at a higher scope

  try {
    // 1. Extract parameters from the request body
    const { tenantId, fileBase64, mimeType, fileName, uploadContext, contextId, branchId, userId } = await req.json();
    if (!tenantId || !fileBase64 || !mimeType || !fileName || !uploadContext || !contextId) {
      return new Response(JSON.stringify({ error: 'Missing required body parameters: tenantId, fileBase64, mimeType, fileName, uploadContext, contextId are required.' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // 2. Create Supabase admin client
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    // Get platform name from tenantId
    const { data: tenantData, error: tenantError } = await supabaseAdmin
      .from('tenants')
      .select('platform_id')
      .eq('id', tenantId)
      .single();

    if (tenantError) throw new Error(`Failed to fetch tenant to get platform_id: ${tenantError.message}`);
    if (!tenantData) throw new Error(`Tenant with id ${tenantId} not found.`);

    const platformId = tenantData.platform_id;

    const { data: platformData, error: platformError } = await supabaseAdmin
      .from('platforms')
      .select('name')
      .eq('id', platformId)
      .single();

    if (platformError) throw new Error(`Failed to fetch platform name: ${platformError.message}`);
    if (!platformData) throw new Error(`Platform with id ${platformId} not found.`);

    const platformName = platformData.name;

    // 3. Determine the correct tenantId for the integration lookup
    let integrationTenantId = tenantId;
    if (uploadContext === 'Avatars') {
      const { data: ownerId, error: rpcError } = await supabaseAdmin.rpc('get_system_owner_tenant_id');
      if (rpcError) throw new Error(`Could not get system owner tenant ID: ${rpcError.message}`);
      if (!ownerId) throw new Error('System owner tenant ID not found.');
      integrationTenantId = ownerId;
    }

    // 4. Fetch the Google Drive integration using the determined tenantId
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

    // 5. Decrypt the refresh_token
    const { data: decryptedResponse, error: decryptError } = await supabaseAdmin.functions.invoke(
      'decrypt-secret',
      { body: { encryptedData: googleDriveIntegration.encrypted_credentials, iv: googleDriveIntegration.nonce } }
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

      if (errorBody.error === 'invalid_grant') {
        console.error(`invalid_grant error for integration ID: ${googleDriveIntegration.id}. Deactivating integration.`);
        await supabaseAdmin
          .from('tenant_integrations')
          .update({ is_active: false, updated_at: new Date().toISOString() })
          .eq('id', googleDriveIntegration.id);
        
        throw new Error('La conexión con Google ha expirado. Por favor, vuelve a conectar tu cuenta desde la configuración.');
      }

      throw new Error(`Google token refresh failed: ${JSON.stringify(errorBody)}`);
    }

    const tokens = await tokenResponse.json();
    accessToken = tokens.access_token; // Assign to higher-scoped variable

    // ... (rest of the code) ...

    const driveFile = await uploadResponse.json();
    fileId = driveFile.id; // Assign to higher-scoped variable

    // 8. Make the file public
    await fetch(
      `https://www.googleapis.com/drive/v3/files/${fileId}/permissions`,
      {
        method: 'POST',
        headers: { 'Authorization': `Bearer ${accessToken}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ role: 'reader', type: 'anyone' }),
      }
    );

    // 9. Post-upload processing based on context
    let oldFileId: string | null = null;

    switch (uploadContext) {
      case 'TenantLogo': {
        // First, get the old logo_url
        const { data: currentTenant, error: fetchError } = await supabaseAdmin
          .from('tenants')
          .select('logo_url')
          .eq('id', contextId)
          .single();
        
        if (fetchError) {
          console.error(`Could not fetch tenant to get old logo_url: ${fetchError.message}`);
        } else if (currentTenant?.logo_url) {
          oldFileId = currentTenant.logo_url;
        }

        // Now, update the tenant with the new logo
        const { error: tenantUpdateError } = await supabaseAdmin
          .from('tenants')
          .update({ logo_url: fileId })
          .eq('id', contextId); // contextId is the tenantId

        if (tenantUpdateError) {
          // TODO: Consider deleting the file from Google Drive if DB insert fails
          throw new Error(`Failed to update tenant logo_url: ${tenantUpdateError.message}`);
        }
        break;
      }
      case 'ServiceEvidence': {
        if (!branchId || !userId) {
          throw new Error('Missing branchId or userId for ServiceEvidence context.');
        }
        
        const fileBuffer = Uint8Array.from(atob(fileBase64), c => c.charCodeAt(0));
        const fileSize = fileBuffer.length;

        const { error: dbError } = await supabaseAdmin
          .from('attention_service_evidences')
          .insert({
            attention_service_id: contextId,
            google_drive_file_id: fileId,
            file_name: newFileName,
            mime_type: mimeType,
            file_size: fileSize, // Añadido
            tenant_id: tenantId,
            branch_id: branchId,
            user_id: userId,
          });
        if (dbError) {
          // TODO: Consider deleting the file from Google Drive if DB insert fails
          throw new Error(`Failed to save evidence record to database: ${dbError.message}`);
        }
        break;
      }
      case 'PaymentEvidence': {
        if (!branchId || !userId) {
          throw new Error('Missing branchId or userId for PaymentEvidence context.');
        }
        
        const fileBuffer = Uint8Array.from(atob(fileBase64), c => c.charCodeAt(0));
        const fileSize = fileBuffer.length;

        const { error: dbError } = await supabaseAdmin
          .from('attention_payment_evidences')
          .insert({
            attention_payment_id: contextId,
            google_drive_file_id: fileId,
            file_name: newFileName,
            mime_type: mimeType,
            file_size: fileSize,
            tenant_id: tenantId,
            branch_id: branchId,
            user_id: userId,
          });
        if (dbError) {
          // TODO: Consider deleting the file from Google Drive if DB insert fails
          throw new Error(`Failed to save payment evidence record to database: ${dbError.message}`);
        }
        break;
      }
      case 'Treatments': {
        const fileBuffer = Uint8Array.from(atob(fileBase64), c => c.charCodeAt(0));
        const fileSize = fileBuffer.length;

        const { error: dbError } = await supabaseAdmin
          .from('treatment_images')
          .insert({
            treatment_id: contextId,
            google_drive_file_id: fileId,
            image_url: `https://drive.google.com/uc?id=${fileId}`,
            file_name: newFileName,
            mime_type: mimeType,
            file_size: fileSize,
            tenant_id: tenantId,
          });
        if (dbError) {
          throw new Error(`Failed to save treatment image record to database: ${dbError.message}`);
        }
        break;
      }
      case 'Products': { // Corregido de 'ProductImages' a 'Products' para coincidir con el frontend
        const fileBuffer = Uint8Array.from(atob(fileBase64), c => c.charCodeAt(0));
        const fileSize = fileBuffer.length;

        const { error: dbError } = await supabaseAdmin
          .from('product_images')
          .insert({
            product_id: contextId,
            google_drive_file_id: fileId,
            image_url: `https://drive.google.com/uc?id=${fileId}`,
            file_name: newFileName,
            mime_type: mimeType,
            file_size: fileSize, // Añadido
            tenant_id: tenantId,
          });
        if (dbError) {
          // TODO: Consider deleting the file from Google Drive if DB insert fails
          throw new Error(`Failed to save product image record to database: ${dbError.message}`);
        }
        break;
      }
      case 'Services': {
        const fileBuffer = Uint8Array.from(atob(fileBase64), c => c.charCodeAt(0));
        const fileSize = fileBuffer.length;

        const { error: dbError } = await supabaseAdmin
          .from('service_images')
          .insert({
            service_id: contextId,
            google_drive_file_id: fileId,
            image_url: `https://drive.google.com/uc?id=${fileId}`,
            file_name: newFileName,
            mime_type: mimeType,
            file_size: fileSize,
            tenant_id: tenantId,
          });
        if (dbError) {
          // TODO: Consider deleting the file from Google Drive if DB insert fails
          throw new Error(`Failed to save service image record to database: ${dbError.message}`);
        }
        break;
      }
      case 'Combos': {
        const fileBuffer = Uint8Array.from(atob(fileBase64), c => c.charCodeAt(0));
        const fileSize = fileBuffer.length;

        const { error: dbError } = await supabaseAdmin
          .from('combo_images')
          .insert({
            combo_id: contextId,
            google_drive_file_id: fileId,
            image_url: `https://drive.google.com/uc?id=${fileId}`,
            file_name: newFileName,
            mime_type: mimeType,
            file_size: fileSize,
            tenant_id: tenantId,
          });
        if (dbError) {
          // TODO: Consider deleting the file from Google Drive if DB insert fails
          throw new Error(`Failed to save combo image record to database: ${dbError.message}`);
        }
        break;
      }
      case 'BranchPhoto': {
        if (!branchId || !userId) {
          throw new Error('Missing branchId or userId for BranchPhoto context.');
        }
        
        const fileBuffer = Uint8Array.from(atob(fileBase64), c => c.charCodeAt(0));
        const fileSize = fileBuffer.length;

        const { count, error: countError } = await supabaseAdmin
          .from('branch_photos')
          .select('*', { count: 'exact', head: true })
          .eq('branch_id', contextId) // contextId is branchId for this context
          .eq('tenant_id', tenantId);
        
        if (countError) throw countError;
        const isFirstPhoto = count === 0;

        const { error: dbError } = await supabaseAdmin
          .from('branch_photos')
          .insert({
            branch_id: contextId,
            google_drive_file_id: fileId,
            file_name: newFileName,
            mime_type: mimeType,
            file_size: fileSize,
            tenant_id: tenantId,
            is_primary: isFirstPhoto,
          });
        if (dbError) {
          // TODO: Consider deleting the file from Google Drive if DB insert fails
          throw new Error(`Failed to save branch photo record to database: ${dbError.message}`);
        }
        break;
      }
      case 'Chatter': {
        if (!userId || !tenantId) {
          throw new Error('Missing userId or tenantId for Chatter context.');
        }
        
        const fileBuffer = Uint8Array.from(atob(fileBase64), c => c.charCodeAt(0));
        const fileSize = fileBuffer.length;

        const { error: dbError } = await supabaseAdmin
          .from('chatter_attachments')
          .insert({
            chatter_comment_id: contextId,
            google_drive_file_id: fileId,
            file_name: newFileName,
            mime_type: mimeType,
            file_size: fileSize,
            tenant_id: tenantId,
            user_id: userId,
          });
        if (dbError) {
          // TODO: Consider deleting the file from Google Drive if DB insert fails
          throw new Error(`Failed to save chatter attachment record to database: ${dbError.message}`);
        }
        break;
      }
      case 'ConsentSignature': {
        if (!branchId || !userId) {
          throw new Error('Missing branchId or userId for ConsentSignature context.');
        }
        
        const fileBuffer = Uint8Array.from(atob(fileBase64), c => c.charCodeAt(0));
        const fileSize = fileBuffer.length;

        const { error: dbError } = await supabaseAdmin
          .from('consent_signatures')
          .insert({
            signed_consent_id: contextId,
            google_drive_file_id: fileId,
            file_name: newFileName,
            mime_type: mimeType,
            file_size: fileSize,
            tenant_id: tenantId,
            branch_id: branchId,
            user_id: userId,
          });
        if (dbError) {
          // TODO: Consider deleting the file from Google Drive if DB insert fails
          throw new Error(`Failed to save consent signature record to database: ${dbError.message}`);
        }
        break;
      }
      // Add other cases for different upload contexts here in the future
      default:
        // No specific post-upload action required for this context
        break;
    }

    // 10. Return the new fileId and the old one if it was replaced
    return new Response(JSON.stringify({ success: true, fileId: fileId, oldFileId: oldFileId }), {
      status: 200,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });

  } catch (error) {
    console.error('Error in generic Google Drive upload flow:', error);
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});
