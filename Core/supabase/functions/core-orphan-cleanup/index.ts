import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { getCoreSupabaseClient } from '../_shared/supabaseClients.ts';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

// Helper to get a Google Drive access token
async function getGoogleAccessToken() {
  const coreSupabase = getCoreSupabaseClient();
  
  // 1. Find the system owner tenant
  const { data: ownerTenant, error: ownerError } = await coreSupabase
    .from('tenants')
    .select('id')
    .eq('is_system_owner', true)
    .single();

  if (ownerError) throw new Error(`Could not find system owner tenant: ${ownerError.message}`);
  
  const ownerTenantId = ownerTenant.id;

  // 2. Fetch the Google Drive integration for the system owner
  const { data: googleDriveIntegration, error: fetchError } = await coreSupabase
    .from('tenant_integrations')
    .select('*')
    .eq('tenant_id', ownerTenantId)
    .eq('provider', 'google_drive')
    .single();

  if (fetchError) throw new Error(`Failed to fetch Google Drive integration for system owner: ${fetchError.message}`);
  if (!googleDriveIntegration.encrypted_credentials || !googleDriveIntegration.nonce) {
    throw new Error('System owner Google Drive integration is missing encrypted credentials.');
  }

  // 3. Decrypt the refresh_token
  const { data: decryptedResponse, error: decryptError } = await coreSupabase.functions.invoke(
    'decrypt-secret',
    { body: { encryptedData: googleDriveIntegration.encrypted_credentials, iv: googleDriveIntegration.nonce } }
  );
  if (decryptError) throw new Error(`Failed to invoke decrypt-secret function: ${decryptError.message}`);
  
  const refreshToken = decryptedResponse.decryptedText;
  if (!refreshToken) throw new Error('Decryption response did not contain "decryptedText".');

  // 4. Use the refresh_token to get a new access_token
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
    throw new Error(`Google token refresh failed: ${JSON.stringify(errorBody)}`);
  }

  const tokens = await tokenResponse.json();
  return tokens.access_token;
}

// Helper to list all files in a specific Google Drive folder recursively
async function listAllFiles(accessToken: string, folderId: string, pageToken?: string): Promise<{ id: string }[]> {
  const query = `'${folderId}' in parents and trashed = false`;
  let url = `https://www.googleapis.com/drive/v3/files?q=${encodeURIComponent(query)}&fields=files(id),nextPageToken&pageSize=1000`;
  if (pageToken) {
    url += `&pageToken=${pageToken}`;
  }

  const response = await fetch(url, {
    headers: { 'Authorization': `Bearer ${accessToken}` },
  });

  if (!response.ok) {
    throw new Error(`Google Drive API error while listing files: ${await response.text()}`);
  }

  const result = await response.json();
  const files = result.files || [];

  if (result.nextPageToken) {
    const nextFiles = await listAllFiles(accessToken, folderId, result.nextPageToken);
    files.push(...nextFiles);
  }

  return files;
}

// Helper to find a folder by name
async function findFolderIdByName(accessToken: string, folderName: string) {
    const query = `name = '${folderName}' and mimeType = 'application/vnd.google-apps.folder' and 'root' in parents and trashed = false`;
    const searchResponse = await fetch( `https://www.googleapis.com/drive/v3/files?q=${encodeURIComponent(query)}&fields=files(id)`,
        { headers: { 'Authorization': `Bearer ${accessToken}` } }
    );
    if (!searchResponse.ok) throw new Error(`Failed to search for folder '${folderName}'.`);
    const searchResult = await searchResponse.json();
    if (searchResult.files.length === 0) {
        console.log(`Folder "${folderName}" not found. No files to clean up.`);
        return null;
    }
    return searchResult.files[0].id;
}

serve(async (_req) => {
  try {
    console.log('Starting Core orphan file cleanup job...');
    const startTime = Date.now();
    
    const coreSupabase = getCoreSupabaseClient();
    
    // 1. Get Google Access Token
    console.log('Fetching Google access token...');
    const accessToken = await getGoogleAccessToken();
    console.log('Successfully fetched Google access token.');

    // 2. Get all logo_url IDs from the Core database
    console.log('Fetching all logo_url file IDs from the tenants table...');
    const { data: tenantLogos, error: logoError } = await coreSupabase.from('tenants').select('logo_url');
    if (logoError) throw logoError;

    const dbFileIds = new Set<string>();
    tenantLogos.forEach(item => {
      if (item.logo_url) dbFileIds.add(item.logo_url);
    });

    console.log(`Found ${dbFileIds.size} unique file IDs in the Core database.`);

    // 3. List all files in the relevant GDrive folder
    const foldersToScan = ['Logos']; 
    const gdriveFileIds = new Set<string>();
    
    for (const folderName of foldersToScan) {
      const folderId = await findFolderIdByName(accessToken, folderName);
      if (folderId) {
        console.log(`Scanning folder "${folderName}" (ID: ${folderId})...`);
        const files = await listAllFiles(accessToken, folderId);
        files.forEach(f => gdriveFileIds.add(f.id));
      }
    }
    console.log(`Found ${gdriveFileIds.size} total files in Google Drive folder(s).`);

    // 4. Identify and delete orphans
    let deletedCount = 0;
    const deletionPromises = [];

    for (const fileId of gdriveFileIds) {
      if (!dbFileIds.has(fileId)) {
        console.log(`Found orphan file in Core folders: ${fileId}. Scheduling for deletion.`);
        const deleteUrl = `https://www.googleapis.com/drive/v3/files/${fileId}`;
        const deletePromise = fetch(deleteUrl, {
          method: 'DELETE',
          headers: { 'Authorization': `Bearer ${accessToken}` },
        }).then(response => {
          if (response.ok) {
            deletedCount++;
            console.log(`Successfully deleted Core orphan file: ${fileId}`);
          } else {
            console.error(`Failed to delete Core orphan file ${fileId}: ${response.statusText}`);
          }
        }).catch(err => {
            console.error(`Exception while deleting Core orphan file ${fileId}:`, err);
        });
        deletionPromises.push(deletePromise);
      }
    }
    
    await Promise.all(deletionPromises);
    
    const duration = (Date.now() - startTime) / 1000;
    console.log(`Core cleanup job finished in ${duration} seconds. Deleted ${deletedCount} orphan files.`);

    return new Response(JSON.stringify({
      success: true,
      scanned_db_files: dbFileIds.size,
      scanned_gdrive_files: gdriveFileIds.size,
      orphans_deleted: deletedCount,
      duration_seconds: duration,
    }), { headers: corsHeaders });

  } catch (error) {
    console.error('Error during Core orphan file cleanup:', error);
    return new Response(JSON.stringify({ success: false, error: error.message }), {
      status: 500,
      headers: corsHeaders,
    });
  }
});
