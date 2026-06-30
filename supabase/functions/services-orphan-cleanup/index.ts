import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { getTenantSupabaseClient, getCoreSupabaseClient } from '../_shared/supabaseClients.ts';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

// Helper to get a Google Drive access token from the Core backend
async function getGoogleAccessToken() {
  const coreSupabase = getCoreSupabaseClient();
  const internalSecret = Deno.env.get('INTERNAL_SERVICE_SECRET');
  if (!internalSecret) {
    throw new Error('INTERNAL_SERVICE_SECRET is not set in environment.');
  }

  const { data, error } = await coreSupabase.functions.invoke('core-actions', {
    body: { action: 'get_google_drive_service_token' },
    headers: { 'X-Internal-Service-Secret': internalSecret },
  });

  if (error) {
    throw new Error(`Failed to get Google access token: ${error.message || JSON.stringify(error)}`);
  }

  if (!data.access_token) {
    throw new Error('No access_token returned from get_google_drive_service_token action.');
  }
  return data.access_token;
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

// Helper to get the root folder ID for the tenant
async function getTenantRootFolderId(accessToken: string, platformName: string, tenantId: string) {
    // This logic should mirror the folder creation logic in `google-drive-upload`
    const platformFolderName = platformName; 
    const tenantFolderName = tenantId;

    // Find platform folder first
    const platformQuery = `name = '${platformFolderName}' and mimeType = 'application/vnd.google-apps.folder' and 'root' in parents and trashed = false`;
    const searchResponse = await fetch( `https://www.googleapis.com/drive/v3/files?q=${encodeURIComponent(platformQuery)}&fields=files(id)`,
        { headers: { 'Authorization': `Bearer ${accessToken}` } }
    );
    if (!searchResponse.ok) throw new Error('Failed to search for platform folder.');
    const searchResult = await searchResponse.json();
    if (searchResult.files.length === 0) {
        console.log(`Platform folder "${platformFolderName}" not found. No files to clean up.`);
        return null;
    }
    const platformFolderId = searchResult.files[0].id;

    // Find tenant folder inside platform folder
    const tenantQuery = `name = '${tenantFolderName}' and mimeType = 'application/vnd.google-apps.folder' and '${platformFolderId}' in parents and trashed = false`;
    const tenantSearchResponse = await fetch(`https://www.googleapis.com/drive/v3/files?q=${encodeURIComponent(tenantQuery)}&fields=files(id)`,
        { headers: { 'Authorization': `Bearer ${accessToken}` } }
    );
    if (!tenantSearchResponse.ok) throw new Error('Failed to search for tenant folder.');
    const tenantSearchResult = await tenantSearchResponse.json();
    if (tenantSearchResult.files.length === 0) {
        console.log(`Tenant folder "${tenantFolderName}" not found. No files to clean up.`);
        return null;
    }
    return tenantSearchResult.files[0].id;
}


serve(async (_req) => {
  try {
    console.log('Starting orphan file cleanup job...');
    const startTime = Date.now();
    
    const tenantSupabase = getTenantSupabaseClient();
    const coreSupabase = getCoreSupabaseClient();

    const tenantId = Deno.env.get('TENANT_ID'); // Assume this is set in the environment for the function
    const platformId = Deno.env.get('PLATFORM_ID'); // Assume this is set in the environment for the function

    if (!tenantId || !platformId) {
        throw new Error("TENANT_ID and PLATFORM_ID must be set in the function's environment variables.");
    }
    
    // 1. Get Google Access Token
    console.log('Fetching Google access token...');
    const accessToken = await getGoogleAccessToken();
    console.log('Successfully fetched Google access token.');

    // 2. Get all file IDs from the tenant's database
    console.log('Fetching all Google Drive file IDs from the database...');
    const tablesToQuery = [
        'combo_images', 'product_images', 'service_images', 'treatment_images',
        'attention_payment_evidences', 'attention_service_evidences',
        'commission_payment_evidences', 'consent_signatures', 'branch_photos',
        'user_avatars'
    ];

    const dbFileIdPromises = tablesToQuery.map(table => 
      tenantSupabase.from(table).select('google_drive_file_id')
    );
    
    const results = await Promise.all(dbFileIdPromises);
    const dbFileIds = new Set<string>();
    
    results.forEach((result, index) => {
      if (result.error) {
        console.warn(`Could not query table "${tablesToQuery[index]}":`, result.error.message);
        return;
      }
      result.data.forEach(item => {
        if (item.google_drive_file_id) {
          dbFileIds.add(item.google_drive_file_id);
        }
      });
    });

    console.log(`Found ${dbFileIds.size} unique file IDs in the database.`);

    // 3. Get the tenant's root folder ID in Google Drive
    const { data: platformData } = await coreSupabase.from('platforms').select('name').eq('id', platformId).single();
    if (!platformData) throw new Error(`Platform with ID ${platformId} not found.`);
    
    console.log(`Fetching root folder ID for tenant ${tenantId} under platform ${platformData.name}...`);
    const tenantRootFolderId = await getTenantRootFolderId(accessToken, platformData.name, tenantId);

    if (!tenantRootFolderId) {
      console.log('Tenant root folder not found in Google Drive, cleanup finished.');
      const duration = (Date.now() - startTime) / 1000;
      return new Response(JSON.stringify({ success: true, message: "Tenant root folder not found, nothing to do.", duration_seconds: duration }), { headers: corsHeaders });
    }
    console.log(`Found tenant root folder ID: ${tenantRootFolderId}`);
    
    // 4. List all files in the tenant's GDrive folder
    console.log('Listing all files in Google Drive folder...');
    const gdriveFiles = await listAllFiles(accessToken, tenantRootFolderId);
    const gdriveFileIds = new Set(gdriveFiles.map(f => f.id));
    console.log(`Found ${gdriveFileIds.size} files in Google Drive.`);

    // 5. Identify and delete orphans
    let deletedCount = 0;
    const deletionPromises = [];

    for (const fileId of gdriveFileIds) {
      if (!dbFileIds.has(fileId)) {
        console.log(`Found orphan file: ${fileId}. Scheduling for deletion.`);
        const deleteUrl = `https://www.googleapis.com/drive/v3/files/${fileId}`;
        const deletePromise = fetch(deleteUrl, {
          method: 'DELETE',
          headers: { 'Authorization': `Bearer ${accessToken}` },
        }).then(response => {
          if (response.ok) {
            deletedCount++;
            console.log(`Successfully deleted orphan file: ${fileId}`);
          } else {
            console.error(`Failed to delete orphan file ${fileId}: ${response.statusText}`);
          }
        }).catch(err => {
            console.error(`Exception while deleting orphan file ${fileId}:`, err);
        });
        deletionPromises.push(deletePromise);
      }
    }
    
    await Promise.all(deletionPromises);
    
    const duration = (Date.now() - startTime) / 1000;
    console.log(`Cleanup job finished in ${duration} seconds. Deleted ${deletedCount} orphan files.`);

    return new Response(JSON.stringify({
      success: true,
      scanned_db_files: dbFileIds.size,
      scanned_gdrive_files: gdriveFileIds.size,
      orphans_deleted: deletedCount,
      duration_seconds: duration,
    }), { headers: corsHeaders });

  } catch (error) {
    console.error('Error during orphan file cleanup:', error);
    return new Response(JSON.stringify({ success: false, error: error.message }), {
      status: 500,
      headers: corsHeaders,
    });
  }
});
