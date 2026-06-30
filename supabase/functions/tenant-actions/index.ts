import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { getTenantSupabaseClient, getCoreSupabaseClient } from '../_shared/supabaseClients.ts';
import { AuditService } from '../_shared/AuditService.ts';
import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { jwtDecode } from "https://esm.sh/jwt-decode@4.0.0";

const callRpc = async (supabaseAdmin: any, rpcName: string, ...params: any[]) => {
  console.log(`Calling RPC: ${rpcName} with params: ${JSON.stringify(params)}`);
  const { data, error } = await supabaseAdmin.rpc(rpcName, ...params);
  console.log(`RPC ${rpcName} returned - data: ${JSON.stringify(data)}, error: ${JSON.stringify(error)}`);

  if (error) {
    // If error is an empty object or doesn't have a message, create a new Error
    if (typeof error === 'object' && error !== null && !('message' in error)) {
      throw new Error(`RPC Error for ${rpcName}: ${JSON.stringify(error)}`);
    }
    throw error; // Re-throw the original error if it has a message
  }
  return data;
};

// Helper function to queue a notification for a client
const queueClientNotification = async (
  supabaseAdmin: any,
  tenantId: string,
  clientId: string,
  templateType: string,
  templateData: object
) => {
  try {
    // 1. Get client email locally (Tenant DB)
    const { data: clientData, error: clientError } = await supabaseAdmin
      .from('clients')
      .select('email')
      .eq('id', clientId)
      .single();

    if (clientError || !clientData?.email) {
      console.error(`[Notification] Failed to get email for client ${clientId}:`, clientError);
      return;
    }

    // 2. Queue in Core via RPC
    const coreSupabase = getCoreSupabaseClient();
    const { error } = await coreSupabase.rpc('queue_client_email', {
      p_tenant_id: tenantId,
      p_recipient_client_id: clientId,
      p_recipient_email: clientData.email,
      p_template_type: templateType,
      p_template_data: templateData,
    });

    if (error) {
      console.error(
        `Failed to queue notification ${templateType} for client ${clientId} in Core:`,
        error
      );
    }
  } catch (e) {
    console.error(
      `Exception while queueing notification ${templateType} for client ${clientId}:`,
      e
    );
  }
};

// Helper function to create a notification for a user
const createUserNotification = async (
  supabaseAdmin: any,
  tenantId: string,
  userId: string,
  type: string,
  title: string,
  body: string,
  linkTo: string
) => {
  try {
    const { error } = await supabaseAdmin.rpc('create_notification', {
      p_tenant_id: tenantId,
      p_user_id: userId,
      p_type: type,
      p_title: title,
      p_body: body,
      p_link_to: linkTo,
    });

    if (error) {
      console.error(
        `Failed to create notification for user ${userId} with title "${title}":`,
        error
      );
    }
  } catch (e) {
    console.error(
      `Exception while creating notification for user ${userId}:`,
      e
    );
  }
};

// Helper function to log field changes for a resource to the chatter
const logFieldChangesToChatter = async (
  supabase: any,
  tenantId: string,
  platformId: string,
  userId: string,
  resourceType: string,
  resourceId: string,
  oldRecord: Record<string, any>,
  newUpdates: Record<string, any>
) => {
  const eventsToLog = [];
  const fieldsToIgnore = ['updated_at', 'created_at', 'id', 'tenant_id', 'platform_id']; // Fields to ignore in audit

  for (const key in newUpdates) {
    if (Object.prototype.hasOwnProperty.call(newUpdates, key) && !fieldsToIgnore.includes(key)) {
      // Ensure we are comparing values of the same type if possible, especially for null/undefined vs empty string
      const oldValue = oldRecord[key] ?? null;
      const newValue = newUpdates[key] ?? null;

      if (oldValue !== newValue) {
        eventsToLog.push({
          tenant_id: tenantId,
          platform_id: platformId,
          user_id: userId,
          resource_type: resourceType,
          resource_id: resourceId,
          event_type: 'field_update',
          payload: {
            field: key,
            old_value: oldValue,
            new_value: newValue,
          },
        });
      }
    }
  }

  if (eventsToLog.length > 0) {
    try {
      const { error } = await supabase.from('chatter_events').insert(eventsToLog);
      if (error) {
        console.error('Failed to log field changes to chatter:', error);
      }
    } catch (e) {
      console.error('Exception while logging field changes to chatter:', e);
    }
  }
};

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

// Helper function to get subscription usage details
const _getSubscriptionUsageDetails = async (supabaseAdmin: any, coreSupabase: any, tenantId: string) => {
  // 1. Get active subscription, its limits, and asset details (including purposes) from CORE
  console.log(`[Usage] Fetching active subscription for tenant: ${tenantId} from Core`);
  const { data: subData, error: subError } = await coreSupabase
    .from('tenant_subscriptions')
    .select(`
      id,
      start_date,
      end_date,
      plan_country_configurations (
        id,
        subscription_plans ( name ),
        plan_asset_limits (
          id,
          value,
          plan_assets (
            id,
            asset_key,
            name,
            description,
            asset_purposes ( purpose_key )
          )
        )
      )
    `)
    .eq('tenant_id', tenantId)
    .eq('is_active', true);

  if (subError) {
    throw new Error(`Core DB Error fetching subscription: ${subError.message}`);
  }
  if (!subData || !subData.length) {
    console.log(`[Usage] No active subscription found for tenant: ${tenantId}`);
    return { plan_name: null, billing_period_start: null, billing_period_end: null, usage: [] };
  }
  console.log(`[Usage] Found subscription ${subData[0].id}`);
  const subscription = subData[0];

  // --- Defensive Checks ---
  if (!subscription.plan_country_configurations) {
    throw new Error(`Data Integrity Error: Subscription ${subscription.id} is missing a valid plan_country_configuration.`);
  }
  const config = subscription.plan_country_configurations;

  if (!config.subscription_plans) {
    throw new Error(`Data Integrity Error: Configuration ${config.id} is missing a valid subscription_plan.`);
  }
  // --- End Checks ---

  const { start_date, end_date } = subscription;
  const planName = config.subscription_plans.name;
  const limits = config.plan_asset_limits || [];

  // 2. Get usage for metered assets (non-storage) for the current billing period from CORE
  console.log(`[Usage] Fetching usage tracking for period: ${start_date} to ${end_date}`);
  const { data: usageData, error: usageError } = await coreSupabase
    .from('asset_usage_tracking')
    .select('asset_id, quantity_used')
    .eq('tenant_id', tenantId)
    .gte('usage_period_start', start_date)
    .lte('usage_period_end', end_date);

  if (usageError) {
    throw new Error(`Core DB Error fetching usage tracking: ${usageError.message}`);
  }
  const usageMap = new Map(usageData.map(u => [u.asset_id, u.quantity_used]));
  console.log(`[Usage] Found ${usageMap.size} usage tracking records.`);

  // 3. Get all bonuses related to the limits of this plan configuration from CORE
  const limitIds = limits.map(l => l.id);
  const { data: allBonuses, error: bonusesError } = await coreSupabase
    .from('plan_asset_bonuses')
    .select('source_asset_limit_id, bonus_asset_id, quantity')
    .in('source_asset_limit_id', limitIds);
  if (bonusesError) {
    throw new Error(`Core DB Error fetching asset bonuses: ${bonusesError.message}`);
  }
  console.log(`[Usage] Found ${allBonuses.length} bonus records.`);

  // 4. Get count of active branches for bonus calculation from SERVICES (Local)
  console.log(`[Usage] Fetching active branch count for tenant: ${tenantId}`);
  const { data: activeBranches, error: branchesError } = await supabaseAdmin
    .from('branches')
    .select('id')
    .eq('tenant_id', tenantId)
    .eq('status', 'active');

  if (branchesError) {
    throw new Error(`Services DB Error fetching branch count: ${branchesError.message}`);
  }
  const activeBranchesCount = activeBranches?.length || 0;
  console.log(`[Usage] Found ${activeBranchesCount} active branches.`);

  // 5. Process all assets, with special handling for storage
  const usageResponse = await Promise.all(limits.map(async (limit) => {
    const asset = limit.plan_assets;
    const assetPurpose = asset.asset_purposes?.purpose_key;
    let used = 0;
    let calculatedLimit = 0;

    let breakdown: any[] | null = null; // New variable

    if (assetPurpose === 'storage') {
      // --- Special handling for STORAGE (Local RPC) ---
      const { data: usageByTable, error: rpcError } = await supabaseAdmin.rpc('get_tenant_storage_usage_by_table', { p_tenant_id: tenantId });
      if (rpcError) {
        console.error(`[Usage] DB Error fetching storage usage breakdown: ${rpcError.message}`);
        throw new Error(`DB Error fetching storage usage breakdown: ${rpcError.message}`);
      }

      used = usageByTable.reduce((sum, record) => sum + (record.size || 0), 0); // Total used space in BYTES
      breakdown = usageByTable; // Store for the response

      let totalLimitGB = parseFloat(limit.value) || 0; // Base storage from plan
      
      // Find the branch limit definition to know how many are included in the base plan
      // Use purpose_key 'extra_branch' as confirmed from DB inspection
      const branchLimitDef = limits.find(l => l.plan_assets.asset_purposes?.purpose_key === 'extra_branch');
      const baseBranchesIncluded = branchLimitDef ? parseFloat(branchLimitDef.value) : 1; 

      const bonusesForThisAsset = allBonuses.filter(b => b.bonus_asset_id === asset.id);

      for (const bonus of bonusesForThisAsset) {
        const sourceLimit = limits.find(l => l.id === bonus.source_asset_limit_id);
        if (sourceLimit) {
          const sourceAssetPurpose = sourceLimit.plan_assets.asset_purposes?.purpose_key;
          
          // Check if the bonus comes from the "Branch" asset (purpose 'extra_branch')
          if (sourceAssetPurpose === 'extra_branch') {
             // Calculate how many EXTRA branches are active beyond the base plan
             // Example: Plan includes 1 branch. 2 active branches. Extra = 1. Bonus applied 1 time.
             const extraBranchesCount = Math.max(0, activeBranchesCount - baseBranchesIncluded);
             totalLimitGB += bonus.quantity * extraBranchesCount;
          } else {
             // Other bonuses (e.g. fixed base storage included in plan) are applied directly once
             totalLimitGB += bonus.quantity;
          }
        }
      }
      calculatedLimit = totalLimitGB * 1024 * 1024 * 1024; // Convert GB to BYTES

    } else if (assetPurpose === 'branch' || assetPurpose === 'extra_branch') {
      used = activeBranchesCount;
      calculatedLimit = parseFloat(limit.value) || 0;
    }
    else {
      used = usageMap.get(asset.id) || 0;
      calculatedLimit = parseFloat(limit.value) || 0;
    }

    const response: any = {
      asset_name: asset.name,
      asset_key: asset.asset_key,
      asset_purpose_key: assetPurpose,
      asset_description: asset.description,
      used: used,
      limit: calculatedLimit,
    };

    if (breakdown) {
      response.breakdown = breakdown;
    }

    return response;
  }));

  return {
    plan_name: planName,
    billing_period_start: start_date,
    billing_period_end: end_date,
    usage: usageResponse,
  };
};

// Helper function to get ONLY storage usage details from the correct DBs
const _getCoreStorageUsage = async (coreSupabase: any, supabaseAdmin: any, tenantId: string) => {
  // 1. Get active subscription and STORAGE asset limit from CORE database
  const { data: subData, error: subError } = await coreSupabase
    .from('tenant_subscriptions')
    .select(`
      plan_country_configurations (
        plan_asset_limits (
          value,
          plan_assets ( asset_key )
        )
      )
    `)
    .eq('tenant_id', tenantId)
    .eq('is_active', true)
    .single();

  if (subError && subError.code !== 'PGRST116') { // Ignore "No rows found"
    throw new Error(`Core DB Error fetching subscription: ${subError.message}`);
  }
  
  const storageLimitAsset = subData?.plan_country_configurations?.plan_asset_limits.find(
    (limit: any) => limit.plan_assets.asset_key === 'storage'
  );
  
  const storageLimitGB = storageLimitAsset ? parseFloat(storageLimitAsset.value) : 0;
  const storageLimitBytes = storageLimitGB * 1024 * 1024 * 1024;

  // 2. Get storage usage breakdown from TENANT database
  const { data: usageByTable, error: rpcError } = await supabaseAdmin.rpc('get_tenant_storage_usage_by_table', { p_tenant_id: tenantId });
  if (rpcError) {
    throw new Error(`Tenant DB Error fetching storage usage breakdown: ${rpcError.message}`);
  }

  const totalSizeBytes = usageByTable.reduce((sum: number, record: any) => sum + (record.size || 0), 0);

  return {
    totalSize: totalSizeBytes,
    storageLimit: storageLimitBytes,
    breakdown: usageByTable,
  };
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  const supabaseAdmin = getTenantSupabaseClient();
  const coreSupabase = getCoreSupabaseClient(); // Available for future steps

  // Helper function to get staff gallery images
  const _getStaffGallery = async (supabaseAdmin: any, tenantId: string, staffId: string) => {
    // 1. Get all attention_service_evidences associated with services performed by the staffId in the given tenantId
    // This requires joining attention_services to attention_service_evidences.
    const { data: servicesWithEvidences, error: evidencesError } = await supabaseAdmin
      .from('attention_services')
      .select(`
        id,
        attention_service_evidences (
          id,
          google_drive_file_id,
          file_name,
          mime_type,
          created_at
        )
      `)
      .eq('tenant_id', tenantId)
      .eq('user_id', staffId) // user_id in attention_services is the professional
      .not('attention_service_evidences', 'is', null); // Only services that have evidences
  
    if (evidencesError) {
      throw new Error(`DB Error fetching attention services with evidences: ${evidencesError.message}`);
    }
  
    // Flatten the structure and collect unique evidence IDs
    const allEvidences: any[] = [];
    const uniqueEvidenceIds = new Set<string>();
  
    for (const service of servicesWithEvidences) {
      if (service.attention_service_evidences && Array.isArray(service.attention_service_evidences)) {
        for (const evidence of service.attention_service_evidences) {
          if (!uniqueEvidenceIds.has(evidence.id)) {
            allEvidences.push(evidence);
            uniqueEvidenceIds.add(evidence.id);
          }
        }
      }
    }
  
    if (allEvidences.length === 0) {
      return []; // No evidences found for this staff member
    }
  
    // 2. Fetch staff_gallery_items for these evidences for the given staffId and tenantId
    const evidenceIds = allEvidences.map(e => e.id);
    const { data: gallerySettings, error: settingsError } = await supabaseAdmin
      .from('staff_gallery_items')
      .select('evidence_id, display_order, is_favorite')
      .eq('tenant_id', tenantId)
      .eq('user_id', staffId)
      .in('evidence_id', evidenceIds);
  
    if (settingsError) {
      throw new Error(`DB Error fetching staff gallery settings: ${settingsError.message}`);
    }
  
    const settingsMap = new Map<string, { display_order: number; is_favorite: boolean }>();
    for (const setting of gallerySettings) {
      settingsMap.set(setting.evidence_id, {
        display_order: setting.display_order,
        is_favorite: setting.is_favorite,
      });
    }
  
    // 3. Combine evidences with their gallery settings and sort
    const combinedGallery = allEvidences.map(evidence => {
      const settings = settingsMap.get(evidence.id);
      return {
        id: evidence.id,
        google_drive_file_id: evidence.google_drive_file_id,
        file_name: evidence.file_name,
        mime_type: evidence.mime_type,
        created_at: evidence.created_at,
        display_order: settings?.display_order ?? 0, // Default to 0 if no setting
        is_favorite: settings?.is_favorite ?? false, // Default to false if no setting
      };
    });
  
    // Sort by display_order, then by created_at (descending for newest first)
    combinedGallery.sort((a, b) => {
      if (a.display_order !== b.display_order) {
        return a.display_order - b.display_order;
      }
      return new Date(b.created_at).getTime() - new Date(a.created_at).getTime();
    });
  
    return combinedGallery;
  };

  // Helper function to update staff gallery images (favorites and order)
  const _updateStaffGallery = async (supabaseAdmin: any, tenantId: string, staffId: string, galleryItems: Array<{ evidence_id: string; display_order: number; is_favorite: boolean }>) => {
    // 1. Validate the number of favorites
    const favoriteCount = galleryItems.filter(item => item.is_favorite).length;
    if (favoriteCount > 10) {
      throw new Error('You can mark a maximum of 10 images as favorites.');
    }
  
    // 2. Prepare data for the RPC call. The RPC only needs evidence_id and display_order.
    const rpcItems = galleryItems.map(item => ({
      evidence_id: item.evidence_id,
      display_order: item.display_order,
    }));
  
    // 3. Call the new RPC function
    const { error } = await supabaseAdmin.rpc('update_staff_gallery_settings', {
      p_tenant_id: tenantId,
      p_user_id: staffId,
      p_gallery_items: rpcItems,
    });
  
    if (error) {
      throw new Error(`DB Error calling update_staff_gallery_settings RPC: ${error.message}`);
    }
  
    // The RPC returns void, so we just return success.
    return { success: true };
  };

  const { action, payload } = await req.json();
  console.log(`Received request for action: "${action}"`);
  let responseData: any = null;
  let status = 200;
  const startTime = performance.now();
  let tenantId: string | undefined;
  let userId: string | undefined;
  let decodedToken: any; // Declared at a higher scope
  let platformId: string | undefined;

  try {
    if (!supabaseAdmin) {
      throw new Error('Supabase Admin client failed to initialize.');
    }

    const publicActions = [];

    if (!publicActions.includes(action)) {
      // --- Authentication (mandatory for non-public actions) ---
      const authHeader = req.headers.get('Authorization');
      if (!authHeader) {
        throw new Error('Missing Authorization Header');
      }
      const token = authHeader.replace('Bearer ', '');
      decodedToken = jwtDecode(token); // Assign value
      userId = decodedToken.sub;
      tenantId = decodedToken.app_metadata?.assignments?.[0]?.tenant_id;
      platformId = decodedToken.app_metadata?.assignments?.[0]?.platform_id;

      console.log('userId from JWT:', userId);

      if (!userId || !tenantId || !platformId) {
        throw new Error('User ID, Tenant ID, or Platform ID not found in JWT.');
      }

      // --- Audit Context ---
      const userAssignments = decodedToken.app_metadata?.assignments || [];
      const branchId = userAssignments[0]?.branch_id;
      const auditContext = {
        user_id: userId,
        tenant_id: tenantId,
        platform_id: platformId,
        branch_id: branchId,
      };
      await supabaseAdmin.rpc('set_audit_context', { p_context: auditContext });
    }

    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      req.headers.get('Authorization') ? { global: { headers: { Authorization: req.headers.get('Authorization')! } } } : {}
    );

    switch (action) {
      case 'get_tenant_storage_usage': {
        // tenantId is available from JWT
        responseData = await _getCoreStorageUsage(coreSupabase, supabaseAdmin, tenantId);
        break;
      }


      // --- AUTHENTICATED ACTIONS ---
      // --- CLIENT ACTIONS ---
      //case 'UPDATE_TV_PLAYBACK_STATE': {
        // This action is called by the TV display page, which may be running anonymously.
        // We bypass the standard user/tenant JWT check for this specific action,
        // as the operation is considered trusted when originating from the TV display logic.
        //const { branch_id, current_playlist_item_id, video_started_at } = payload;
        //if (!branch_id || !current_playlist_item_id || !video_started_at) {
          //throw new Error('branch_id, current_playlist_item_id, and video_started_at are required for UPDATE_TV_PLAYBACK_STATE.');
        //}
  
        //const { data, error } = await supabaseAdmin
          //.from('branch_playback_state')
          //.upsert({
            //branch_id: branch_id,
           // current_playlist_item_id: current_playlist_item_id,
            //video_started_at: video_started_at,
          //}, { onConflict: 'branch_id' })
          //.select()
          //.single();
  
        //if (error) throw error;
        //responseData = data;
        //break;
      //}
      case 'get_clients_by_branch': {
        const { branchId, searchTerm, showInactive } = payload;
        if (!branchId) throw new Error('Branch ID is required.');

        const { data, error } = await supabaseAdmin.rpc('search_clients', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_branch_id: branchId,
          p_search_term: searchTerm,
          p_show_inactive: showInactive,
        });

        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get_sub_clients': {
        const { clientId } = payload;
        if (!clientId) throw new Error('Client ID is required.');

        const { data, error } = await supabaseAdmin
          .from('clients')
          .select('*')
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .eq('parent_client_id', clientId)
          .order('name');

        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get_client_details': {
        const { clientId } = payload;
        if (!clientId) throw new Error('Client ID is required.');

        const { data: clientData, error: clientError } = await supabaseAdmin
          .from('clients')
          .select('*, document_types(name)')
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .eq('id', clientId)
          .single();

        if (clientError) throw clientError;

        const { data: branchData, error: branchError } = await supabaseAdmin
          .from('client_branches')
          .select('branches(id, name)')
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .eq('client_id', clientId);

        if (branchError) throw branchError;

        // --- NUEVO: Obtener profesionales asignados ---
        const { data: assignedProfessionals, error: profError } = await supabaseAdmin
          .from('client_professionals')
          .select('user_id')
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .eq('client_id', clientId);
        if (profError) console.error('Error fetching assigned professionals:', profError);

        // --- NUEVO: Obtener comerciales asignados ---
        const { data: assignedCommercials, error: commError } = await supabaseAdmin
          .from('client_commercials')
          .select('user_id')
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .eq('client_id', clientId);
        if (commError) console.error('Error fetching assigned commercials:', commError);

        responseData = {
          ...clientData,
          branches: branchData.map((b: any) => b.branches),
          professional_ids: assignedProfessionals?.map((p: any) => p.user_id) || [], // NUEVO
          commercial_ids: assignedCommercials?.map((c: any) => c.user_id) || [],   // NUEVO
        };
        break;
      }

      case 'get_client_addresses': {
        const { clientId } = payload;
        if (!clientId) throw new Error('Client ID is required.');

        const { data, error } = await supabaseAdmin
          .from('client_addresses')
          .select('*')
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .eq('client_id', clientId)
          .order('created_at');

        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get_client_contacts': {
        const { clientId } = payload;
        if (!clientId) throw new Error('Client ID is required.');

        const { data, error } = await supabaseAdmin
          .from('client_contacts')
          .select('*, contact_types(name)')
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .eq('client_id', clientId)
          .order('created_at');

        if (error) throw error;
        responseData = data;
        break;
      }

      case 'create_client': {
        const { clientData, branchIds } = payload;
        if (!clientData || !branchIds || branchIds.length === 0) {
          throw new Error('Client data and at least one branch ID are required.');
        }

        const { data: newClient, error: clientError } = await supabaseAdmin
          .from('clients')
          .insert({ ...clientData, tenant_id: tenantId, platform_id: platformId })
          .select()
          .single();

        if (clientError) throw clientError;

        const branchAssignments = branchIds.map((branchId: string) => ({
          client_id: newClient.id,
          branch_id: branchId,
          tenant_id: tenantId,
          platform_id: platformId,
        }));

        const { error: branchError } = await supabaseAdmin
          .from('client_branches')
          .insert(branchAssignments);

        if (branchError) {
          // Rollback client creation if branch assignment fails
          await supabaseAdmin.from('clients').delete().eq('id', newClient.id).eq('tenant_id', tenantId).eq('platform_id', platformId);
          throw branchError;
        }

        // --- Audit Log ---
        await AuditService.logChange(supabaseAdmin, getCoreSupabaseClient(), {
          tenantId: tenantId,
          userId: (payload.user_id) || 'System', // Asumimos user_id en payload o extraído del token
          action: 'INSERT',
          table: 'clients',
          recordId: newClient.id,
          newRecord: newClient
        });

        responseData = newClient;
        break;
      }

      case 'update_client': {
        const { clientId, updates } = payload;
        if (!clientId || !updates) throw new Error('Client ID and updates are required.');

        // Separate the association IDs from the client data
        const { professional_ids, commercial_ids, ...clientUpdates } = updates;

        // Step 1: Fetch the old record for comparison
        const { data: oldClient, error: fetchError } = await supabaseAdmin
          .from('clients')
          .select('*')
          .eq('id', clientId)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .single();

        if (fetchError) {
          throw new Error(`Could not fetch client to update: ${fetchError.message}`);
        }

        // Step 2: Perform the update with only the client fields, if there are any
        let updatedClient = oldClient; // Start with the old client data
        if (Object.keys(clientUpdates).length > 0) {
            const { data, error: updateError } = await supabaseAdmin
              .from('clients')
              .update(clientUpdates)
              .eq('id', clientId)
              .eq('tenant_id', tenantId)
              .eq('platform_id', platformId)
              .select()
              .single();

            if (updateError) throw updateError;
            updatedClient = data; // Update with the new data

            // --- Audit Log (Client Fields) ---
            await AuditService.logChange(supabaseAdmin, getCoreSupabaseClient(), {
              tenantId: tenantId,
              userId: payload.current_user_id || 'System',
              action: 'UPDATE',
              table: 'clients',
              recordId: clientId,
              oldRecord: oldClient,
              newRecord: updatedClient
            });
        }


        // --- NUEVO: Actualizar asignaciones de profesionales ---
        if (professional_ids !== undefined) {
            const { error: deleteProfError } = await supabaseAdmin.from('client_professionals').delete().eq('client_id', clientId).eq('tenant_id', tenantId).eq('platform_id', platformId);
            if (deleteProfError) console.error('Error deleting old client professionals:', deleteProfError);

            if (professional_ids.length > 0) {
                const newAssignments = professional_ids.map((userId: string) => ({
                    client_id: clientId,
                    user_id: userId,
                    tenant_id: tenantId,
                    platform_id: platformId,
                }));
                const { error: insertProfError } = await supabaseAdmin.from('client_professionals').insert(newAssignments);
                if (insertProfError) console.error('Error inserting new client professionals:', insertProfError);
            }
        }

        // --- NUEVO: Actualizar asignaciones de comerciales ---
        if (commercial_ids !== undefined) {
            const { error: deleteCommError } = await supabaseAdmin.from('client_commercials').delete().eq('client_id', clientId).eq('tenant_id', tenantId).eq('platform_id', platformId);
            if (deleteCommError) console.error('Error deleting old client commercials:', deleteCommError);

            if (commercial_ids.length > 0) {
                const newAssignments = commercial_ids.map((userId: string) => ({
                    client_id: clientId,
                    user_id: userId,
                    tenant_id: tenantId,
                    platform_id: platformId,
                }));
                const { error: insertCommError } = await supabaseAdmin.from('client_commercials').insert(newAssignments);
                if (insertCommError) console.error('Error inserting new client commercials:', insertCommError);
            }
        }

        // Step 3: Log changes to chatter (fire and forget)
        if (Object.keys(clientUpdates).length > 0) {
          await logFieldChangesToChatter(
            supabaseClient, // Use client with user's role to insert
            tenantId,
            platformId,
            userId,
            'client', // resource_type
            clientId, // resource_id
            oldClient, // old record
            clientUpdates    // new values
          );
        }

        // Re-fetch the client to get the most up-to-date data including new relations
        // This is necessary because the .update() doesn't return the joined data
        const { data: finalClientData, error: finalFetchError } = await supabaseAdmin
          .from('clients')
          .select('*, document_types(name)')
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .eq('id', clientId)
          .single();

        if (finalFetchError) {
          console.error("Error re-fetching client after update:", finalFetchError);
          // If the refetch fails, construct the response manually as a fallback
          responseData = {
            ...updatedClient,
            professional_ids: professional_ids || oldClient.professional_ids || [],
            commercial_ids: commercial_ids || oldClient.commercial_ids || [],
            // Note: other relational data like `branches` will be stale
          };
        } else {
            // --- Re-fetch branch and association data ---
            const { data: branchData, error: branchError } = await supabaseAdmin
              .from('client_branches')
              .select('branches(id, name)')
              .eq('tenant_id', tenantId)
              .eq('platform_id', platformId)
              .eq('client_id', clientId);
            if (branchError) console.error('Error re-fetching client branches:', branchError);

            const { data: assignedProfessionals, error: profError } = await supabaseAdmin
              .from('client_professionals')
              .select('user_id')
              .eq('tenant_id', tenantId)
              .eq('platform_id', platformId)
              .eq('client_id', clientId);
            if (profError) console.error('Error re-fetching assigned professionals:', profError);

            const { data: assignedCommercials, error: commError } = await supabaseAdmin
              .from('client_commercials')
              .select('user_id')
              .eq('tenant_id', tenantId)
              .eq('platform_id', platformId)
              .eq('client_id', clientId);
            if (commError) console.error('Error re-fetching assigned commercials:', commError);

            responseData = {
              ...finalClientData,
              branches: branchData?.map((b: any) => b.branches) || [],
              professional_ids: assignedProfessionals?.map((p: any) => p.user_id) || [],
              commercial_ids: assignedCommercials?.map((c: any) => c.user_id) || [],
            };
        }
        
        break;
      }

      case 'delete_client': {
        const { clientId } = payload;
        if (!clientId) throw new Error('Client ID is required.');

        // The client_branches entries are deleted by ON DELETE CASCADE
        const { error } = await supabaseAdmin
          .from('clients')
          .delete()
          .eq('id', clientId)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId);

        if (error) throw error;
        responseData = { success: true };
        break;
      }

      // --- NUEVAS ACCIONES PARA OBTENER PROFESIONALES Y COMERCIALES ASIGNABLES ---
      case 'get_assignable_professionals': {
        if (!tenantId) throw new Error('Tenant ID is required.');
        const { data, error } = await supabaseAdmin.rpc('get_assignable_professionals', { p_tenant_id: tenantId, p_platform_id: platformId });
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get_assignable_commercials': {
        if (!tenantId) throw new Error('Tenant ID is required.');
        const { data, error } = await supabaseAdmin.rpc('get_assignable_commercials', { p_tenant_id: tenantId, p_platform_id: platformId });
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get_staff_gallery': {
        const { staff_id } = payload;
        if (!staff_id) throw new Error('Staff ID is required.');
        responseData = await _getStaffGallery(supabaseAdmin, tenantId, platformId, staff_id);
        break;
      }

      case 'update_staff_gallery': {
        const { staff_id, gallery_items } = payload;
        if (!staff_id || !gallery_items) throw new Error('Staff ID and gallery items are required.');
        responseData = await _updateStaffGallery(supabaseAdmin, tenantId, platformId, staff_id, gallery_items);
        break;
      }

      case 'create_client_address': {
        const { client_id, ...addressData } = payload;
        if (!client_id) throw new Error('Client ID is required.');

        const { data, error } = await supabaseAdmin
          .from('client_addresses')
          .insert({ ...addressData, client_id: client_id, tenant_id: tenantId, platform_id: platformId })
          .select()
          .single();

        if (error) throw error;

        await AuditService.logChange(supabaseAdmin, getCoreSupabaseClient(), {
          tenantId,
          userId: payload.current_user_id || 'System',
          action: 'INSERT',
          table: 'client_addresses',
          recordId: data.id,
          newRecord: data
        });

        responseData = data;
        break;
      }

      case 'update_client_address': {
        const { id, ...updates } = payload;
        if (!id) throw new Error('Address ID is required.');

        // Fetch old for audit
        const { data: oldAddress } = await supabaseAdmin.from('client_addresses').select('*').eq('id', id).eq('tenant_id', tenantId).eq('platform_id', platformId).single();

        const { data, error } = await supabaseAdmin
          .from('client_addresses')
          .update(updates)
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .select()
          .single();

        if (error) throw error;

        await AuditService.logChange(supabaseAdmin, getCoreSupabaseClient(), {
          tenantId,
          userId: payload.current_user_id || 'System',
          action: 'UPDATE',
          table: 'client_addresses',
          recordId: id,
          oldRecord: oldAddress,
          newRecord: data
        });

        responseData = data;
        break;
      }

      case 'delete_client_address': {
        const { id } = payload;
        if (!id) throw new Error('Address ID is required.');

        // Fetch old for audit
        const { data: oldAddress } = await supabaseAdmin.from('client_addresses').select('*').eq('id', id).eq('tenant_id', tenantId).eq('platform_id', platformId).single();

        const { error } = await supabaseAdmin
          .from('client_addresses')
          .delete()
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId);

        if (error) throw error;

        if (oldAddress) {
            await AuditService.logChange(supabaseAdmin, getCoreSupabaseClient(), {
              tenantId,
              userId: payload.current_user_id || 'System',
              action: 'DELETE',
              table: 'client_addresses',
              recordId: id,
              oldRecord: oldAddress
            });
        }

        responseData = { success: true };
        break;
      }

      // --- ABSENCE TYPES ACTIONS ---
      case 'get_absence_types': {
        const { showInactive } = payload;
        let query = supabaseAdmin
          .from('absence_types')
          .select('*')
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId);

        if (!showInactive) {
          query = query.eq('is_active', true);
        }

        const { data, error } = await query.order('name');
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'create_absence_type': {
        const { name, description } = payload;
        if (!name) throw new Error('Absence type name is required.');
        const { data, error } = await supabaseAdmin
          .from('absence_types')
          .insert({ tenant_id: tenantId, platform_id: platformId, name, description, is_active: true })
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'update_absence_type': {
        const { id, ...updates } = payload;
        if (!id) throw new Error('Absence type ID is required.');
        const { data, error } = await supabaseAdmin
          .from('absence_types')
          .update(updates)
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'delete_absence_type': {
        const { id } = payload;
        if (!id) throw new Error('Absence type ID is required.');
        // Instead of deleting, we set is_active to false
        const { data, error } = await supabaseAdmin
          .from('absence_types')
          .update({ is_active: false })
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'create_user_time_off': {
        const { user_id, start_date, end_date, absence_type_id, reason, is_partial_day, branch_id } = payload;
        if (!user_id || !start_date || !end_date || !absence_type_id || !branch_id) {
          throw new Error('user_id, start_date, end_date, absence_type_id, and branch_id are required.');
        }

        const { data, error } = await supabaseAdmin
          .from('user_time_off')
          .insert({
            tenant_id: tenantId,
            platform_id: platformId,
            user_id,
            start_date,
            end_date,
            absence_type_id,
            reason,
            is_partial_day,
            branch_id,
            status: 'pending',
          })
          .select()
          .single();

        if (error) throw error;
        responseData = data;
        break;
      }

      case 'create_client_contact': {
        const { client_id, ...contactData } = payload;
        if (!client_id) throw new Error('Client ID is required.');

        const { data, error } = await supabaseAdmin
          .from('client_contacts')
          .insert({ ...contactData, client_id: client_id, tenant_id: tenantId, platform_id: platformId })
          .select()
          .single();

        if (error) throw error;
        
        await AuditService.logChange(supabaseAdmin, getCoreSupabaseClient(), {
          tenantId,
          userId: payload.current_user_id || 'System',
          action: 'INSERT',
          table: 'client_contacts',
          recordId: data.id,
          newRecord: data
        });

        responseData = data;
        break;
      }

      case 'update_client_contact': {
        const { id, ...updates } = payload;
        if (!id) throw new Error('Contact ID is required.');

        // Fetch old for audit
        const { data: oldContact } = await supabaseAdmin.from('client_contacts').select('*').eq('id', id).eq('tenant_id', tenantId).eq('platform_id', platformId).single();

        const { data, error } = await supabaseAdmin
          .from('client_contacts')
          .update(updates)
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .select()
          .single();

        if (error) throw error;

        await AuditService.logChange(supabaseAdmin, getCoreSupabaseClient(), {
          tenantId,
          userId: payload.current_user_id || 'System',
          action: 'UPDATE',
          table: 'client_contacts',
          recordId: id,
          oldRecord: oldContact,
          newRecord: data
        });

        responseData = data;
        break;
      }

      case 'delete_client_contact': {
        const { id } = payload;
        if (!id) throw new Error('Contact ID is required.');

        // Fetch old for audit (crucial for parent linkage)
        const { data: oldContact } = await supabaseAdmin.from('client_contacts').select('*').eq('id', id).eq('tenant_id', tenantId).eq('platform_id', platformId).single();

        const { error } = await supabaseAdmin
          .from('client_contacts')
          .delete()
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId);

        if (error) throw error;

        if (oldContact) {
            await AuditService.logChange(supabaseAdmin, getCoreSupabaseClient(), {
              tenantId,
              userId: payload.current_user_id || 'System',
              action: 'DELETE',
              table: 'client_contacts',
              recordId: id,
              oldRecord: oldContact
            });
        }

        responseData = { success: true };
        break;
      }

      case 'assign_client_to_branch': {
        const { clientId, branchId } = payload;
        if (!clientId || !branchId) throw new Error('Client ID and Branch ID are required.');

        const { data, error } = await supabaseAdmin
          .from('client_branches')
          .insert({
            client_id: clientId,
            branch_id: branchId,
            tenant_id: tenantId,
            platform_id: platformId,
          })
          .select()
          .single();

        if (error) throw error;

        await AuditService.logChange(supabaseAdmin, getCoreSupabaseClient(), {
          tenantId,
          userId: payload.current_user_id || 'System',
          action: 'INSERT',
          table: 'client_branches',
          recordId: data.id || `${clientId}_${branchId}`, // PK compuesta o ID
          newRecord: data
        });

        responseData = data;
        break;
      }

      case 'unassign_client_from_branch': {
        const { clientId, branchId } = payload;
        if (!clientId || !branchId) throw new Error('Client ID and Branch ID are required.');

        const { error } = await supabaseAdmin
          .from('client_branches')
          .delete()
          .eq('client_id', clientId)
          .eq('branch_id', branchId)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId);

        if (error) throw error;
        responseData = { success: true };
        break;
      }

      // --- TENANT SOCIAL NETWORKS ACTIONS ---
      case 'list_tenant_social_networks': {
        const { p_tenant_id, p_platform_id } = payload;
        if (!p_tenant_id || !p_platform_id) throw new Error('Tenant ID and Platform ID are required.');
        responseData = await callRpc(supabaseAdmin, 'list_tenant_social_networks', { p_tenant_id, p_platform_id });
        break;
      }
      case 'add_tenant_social_network': {
        const { p_tenant_id, p_platform_id, network, url } = payload;
        if (!p_tenant_id || !p_platform_id || !network || !url) {
          throw new Error('Tenant ID, Platform ID, network, and URL are required.');
        }
        responseData = await callRpc(supabaseAdmin, 'add_tenant_social_network', { p_tenant_id, p_platform_id, p_network: network, p_url: url });
        break;
      }
      case 'update_tenant_social_network': {
        const { id, p_tenant_id, p_platform_id, network, url } = payload;
        if (!id || !p_tenant_id || !p_platform_id || !network || !url) {
          throw new Error('ID, Tenant ID, Platform ID, network, and URL are required.');
        }
        responseData = await callRpc(supabaseAdmin, 'update_tenant_social_network', { p_id: id, p_tenant_id, p_platform_id, p_network: network, p_url: url });
        break;
      }
      case 'delete_tenant_social_network': {
        const { id, p_tenant_id, p_platform_id } = payload;
        if (!id || !p_tenant_id || !p_platform_id) {
          throw new Error('ID, Tenant ID, and Platform ID are required.');
        }
        responseData = await callRpc(supabaseAdmin, 'delete_tenant_social_network', { p_id: id, p_tenant_id, p_platform_id });
        break;
      }

      // --- BRANCH SOCIAL NETWORKS ACTIONS ---
      case 'list_branch_social_networks': {
        const { p_branch_id } = payload;
        if (!p_branch_id) throw new Error('Branch ID is required.');
        responseData = await callRpc(supabaseAdmin, 'list_branch_social_networks', { p_branch_id: p_branch_id });
        break;
      }
      case 'add_branch_social_network': {
        const { p_branch_id, network, url } = payload;
        if (!p_branch_id || !network || !url) throw new Error('Branch ID, network, and URL are required.');
        responseData = await callRpc(supabaseAdmin, 'add_branch_social_network', { p_branch_id: p_branch_id, p_network: network, p_url: url });
        break;
      }
      case 'update_branch_social_network': {
        const { id, p_branch_id, network, url } = payload;
        if (!id || !p_branch_id || !network || !url) throw new Error('ID, Branch ID, network, and URL are required.');
        responseData = await callRpc(supabaseAdmin, 'update_branch_social_network', { p_id: id, p_branch_id: p_branch_id, p_network: network, p_url: url });
        break;
      }
      case 'delete_branch_social_network': {
        const { id, p_branch_id } = payload;
        if (!id || !p_branch_id) throw new Error('ID and Branch ID are required.');
        responseData = await callRpc(supabaseAdmin, 'delete_branch_social_network', { p_id: id, p_branch_id: p_branch_id });
        break;
      }

      // --- CONSENT TEMPLATE ACTIONS ---
      case 'list_consent_templates': {
        responseData = await callRpc(supabaseAdmin, 'list_consent_templates', { p_tenant_id: tenantId });
        break;
      }

      case 'get_consent_template': {
        const { id } = payload;
        if (!id) throw new Error('Template ID is required.');
        responseData = await callRpc(supabaseAdmin, 'get_consent_template', { p_tenant_id: tenantId, p_id: id });
        break;
      }

      case 'create_consent_template': {
        const { name, content, fields } = payload;
        if (!name) throw new Error('Template name is required.');
        responseData = await callRpc(supabaseAdmin, 'create_consent_template', {
          p_tenant_id: tenantId,
          p_name: name,
          p_content: content,
          p_fields: fields,
        });
        break;
      }

      case 'update_consent_template': {
        const { id, name, content, fields, is_active } = payload;
        if (!id || !name) throw new Error('Template ID and name are required.');
        responseData = await callRpc(supabaseAdmin, 'update_consent_template', {
          p_tenant_id: tenantId,
          p_id: id,
          p_name: name,
          p_content: content,
          p_fields: fields,
          p_is_active: is_active,
        });
        break;
      }

      case 'toggle_consent_template_status': {
        const { id } = payload;
        if (!id) throw new Error('Template ID is required.');
        responseData = await callRpc(supabaseAdmin, 'toggle_consent_template_status', { p_tenant_id: tenantId, p_id: id });
        break;
      }

      // --- APPOINTMENT CONSENT ACTIONS ---
      case 'get_signed_consents_for_attention': {
        const { attention_id, attention_service_id } = payload;
        if (!attention_id) throw new Error('Attention ID is required.');
        responseData = await callRpc(supabaseAdmin, 'get_signed_consents_for_attention', { p_tenant_id: tenantId, p_platform_id: platformId, p_attention_id: attention_id, p_attention_service_id: attention_service_id });
        break;
      }

            case 'assign_consent_to_service': {
              const { attention_id, template_id, attention_service_id, professional_observations } = payload;
              if (!attention_id || !template_id || !attention_service_id) throw new Error('Attention ID, Template ID, and Attention Service ID are required.');
              responseData = await callRpc(supabaseAdmin, 'assign_consent_to_service', {
                p_tenant_id: tenantId,
                p_platform_id: platformId,
                p_attention_id: attention_id,
                p_template_id: template_id,
                p_attention_service_id: attention_service_id,
                p_professional_observations: professional_observations
              });
              break;
            }
            // NEW CASE
            case 'delete_signed_consent': {
              const { signed_consent_id } = payload;
              if (!signed_consent_id) throw new Error('Signed Consent ID is required.');
              responseData = await callRpc(supabaseAdmin, 'delete_signed_consent', { p_tenant_id: tenantId, p_platform_id: platformId, p_signed_consent_id: signed_consent_id });
              break;
            }
      
            case 'link_signature_to_consent': {
              const { signed_consent_id, observations, form_data, signed_content } = payload;
              if (!signed_consent_id) throw new Error('Signed Consent ID is required.');
              if (!form_data) throw new Error('Form data is required.');
              if (!signed_content) throw new Error('Signed content is required.');
      
              responseData = await callRpc(supabaseAdmin, 'link_signature_to_consent', {
                p_tenant_id: tenantId,
                p_platform_id: platformId,
                p_signed_consent_id: signed_consent_id,
                p_observations: observations,
                p_form_data: form_data,
                p_signed_content: signed_content
              });
              break;
            }
      // --- SUBSCRIPTION & BILLING ACTIONS ---
      case 'increment_asset_usage': {
        const { asset_key, quantity_to_add } = payload;
        if (!asset_key || quantity_to_add === undefined) {
          throw new Error('asset_key and quantity_to_add are required.');
        }

        const { error } = await supabaseAdmin.rpc('increment_asset_usage_rpc', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_asset_key: asset_key,
          p_quantity_to_add: quantity_to_add,
        });

        if (error) throw error;
        responseData = { success: true };
        break;
      }

      case 'get_asset_price': {
        const { asset_key } = payload;
        if (!asset_key) throw new Error('asset_key is required.');

        // 1. Call the RPC to get the base price info (either specific or Colombian)
        const { data: priceInfo, error: rpcError } = await supabaseAdmin.rpc('get_price_for_tenant_asset', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_asset_key: asset_key
        });

        if (rpcError) throw rpcError;
        if (!priceInfo || !priceInfo.price) {
          responseData = { final_price: 0, currency_code: 'USD', currency_symbol: '$', source: 'No price defined' };
          break;
        }

        // 2. Get the tenant's currency to determine if conversion is needed
        // (Querying from Core)
        const { data: tenantData, error: tenantError } = await coreSupabase
          .from('tenants')
          .select('countries(currencies(code, symbol))')
          .eq('id', tenantId)
          .eq('platform_id', platformId)
          .single();

        if (tenantError) throw tenantError;
        
        const targetCurrencyCode = tenantData.countries.currencies.code;
        const targetCurrencySymbol = tenantData.countries.currencies.symbol;

        // 3. If the price is already in the target currency, just return it.
        if (priceInfo.currency_code === targetCurrencyCode) {
          responseData = {
            final_price: priceInfo.price,
            currency_code: priceInfo.currency_code,
            currency_symbol: priceInfo.currency_symbol,
            source: priceInfo.source_country
          };
          break;
        }

        // 4. If not, perform the conversion using USD as a bridge
        const baseCurrencyCode = priceInfo.currency_code;

        const { data: rates, error: ratesError } = await coreSupabase
          .from('exchange_rates')
          .select('rate, base_currency_code, target_currency_code')
          .or(`base_currency_code.eq.${baseCurrencyCode},target_currency_code.eq.${baseCurrencyCode},base_currency_code.eq.${targetCurrencyCode},target_currency_code.eq.${targetCurrencyCode}`);

        if (ratesError) throw ratesError;

        const rateToUsd = rates.find((r: any) => r.base_currency_code === baseCurrencyCode && r.target_currency_code === 'USD')?.rate || 1.0;
        const usdToTargetRate = rates.find((r: any) => r.base_currency_code === 'USD' && r.target_currency_code === targetCurrencyCode)?.rate || 1.0;

        const calculatedPrice = Math.floor(priceInfo.price * rateToUsd * usdToTargetRate) + 0.99;

        responseData = {
          final_price: calculatedPrice,
          currency_code: targetCurrencyCode,
          currency_symbol: targetCurrencySymbol,
          source: `${priceInfo.source_country} (Converted)`
        };
        break;
      }

      case 'get_my_subscription_usage': {
        try {
          // Pass coreSupabase to access Core tables
          responseData = await _getSubscriptionUsageDetails(supabaseAdmin, coreSupabase, tenantId, platformId);
        } catch (e) {
          console.error(`[Usage] Error in get_my_subscription_usage action: ${e.message}`);
          throw e; // Re-throw to be caught by the main handler
        }
        break;
      }


      case 'get_monthly_expense_summary': {
        const { branchId: payloadBranchId } = payload;
        const userAssignments = decodedToken.app_metadata?.assignments || [];
        const userRole = userAssignments[0]?.role_name;
        const userBranchId = userAssignments[0]?.branch_id;

        const today = new Date();
        const startOfMonth = new Date(today.getFullYear(), today.getMonth(), 1).toISOString();
        const endOfMonth = new Date(today.getFullYear(), today.getMonth() + 1, 0, 23, 59, 59, 999).toISOString();

        let baseQuery = supabaseAdmin
          .from('expenses')
          .select('amount, status')
          .eq('tenant_id', tenantId)
          .gte('expense_date', startOfMonth)
          .lte('expense_date', endOfMonth);

        if (userRole === 'tenant_super_admin') {
          if (payloadBranchId && payloadBranchId !== 'all') {
            baseQuery = baseQuery.eq('branch_id', payloadBranchId);
          }
        } else if (userRole === 'tenant_admin') {
          if (!userBranchId) {
            throw new Error('Branch ID not found for tenant_admin.');
          }
          baseQuery = baseQuery.eq('branch_id', userBranchId);
        } else {
          throw new Error('Access denied: Insufficient permissions to view expenses summary.');
        }

        const { data: expenses, error } = await baseQuery;

        if (error) throw error;

        const summary = expenses.reduce((acc: { paid: number; pending: number; overdue: number }, expense: { amount: number; status: string }) => {
          const amount = parseFloat(String(expense.amount));
          if (expense.status === 'paid') {
            acc.paid += amount;
          } else if (expense.status === 'pending') {
            acc.pending += amount;
          } else if (expense.status === 'overdue') {
            acc.overdue += amount;
          }
          return acc;
        }, { paid: 0, pending: 0, overdue: 0 });

        responseData = summary;
        break;
      }

      case 'get-dashboard-stats': {
        const { p_tenant_id, p_branch_id, p_user_id, p_timezone } = payload;
        const { data, error } = await supabaseAdmin.rpc('get_dashboard_stats', {
          p_tenant_id,
          p_branch_id,
          p_user_id,
          p_timezone,
        });
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get-today-attentions': {
        const { p_tenant_id, p_branch_id, p_user_id, p_timezone } = payload;
        const { data, error } = await supabaseAdmin.rpc('get_today_attentions', {
          p_tenant_id,
          p_branch_id,
          p_user_id,
          p_timezone,
        });
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get-top-services': {
        const { p_tenant_id, p_branch_id, p_user_id, p_days, p_timezone } = payload;
        const { data, error } = await supabaseAdmin.rpc('get_top_services', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_branch_id,
          p_user_id,
          p_days,
          p_timezone,
        });
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get-pending-commissions': {
        const { p_tenant_id, p_branch_id, p_user_id } = payload;
        const { data, error } = await supabaseAdmin.rpc('get_pending_commissions', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_branch_id,
          p_user_id,
        });
        if (error) throw error;
        responseData = data?.[0]?.total_pending_commissions || 0;
        break;
      }

      case 'get_schedules_for_branch': {
        const { branchId } = payload;
        if (!branchId) throw new Error('Branch ID is required.');
        responseData = await callRpc(supabaseAdmin, 'get_schedules_for_branch', { p_tenant_id: tenantId, p_platform_id: platformId, p_branch_id: branchId });
        break;
      }
      
      case 'get-tenant-details': {
        // tenantId and platformId are available from the authenticated user context.
        // Use the coreSupabase client to query the 'tenants' table and related public tables in the core DB.
        const tenantPromise = coreSupabase
          .from('tenants')
          .select(`
            *,
            countries (
              name,
              iso_code
            )
          `)
          .eq('id', tenantId)
          .eq('platform_id', platformId)
          .single();

        const countriesPromise = coreSupabase.from('countries').select('*');
        const languagesPromise = coreSupabase.from('languages').select('*');
        const currenciesPromise = coreSupabase.from('currencies').select('*');

        const [
          { data: tenantData, error: tenantError },
          { data: countriesData, error: countriesError },
          { data: languagesData, error: languagesError },
          { data: currenciesData, error: currenciesError },
        ] = await Promise.all([tenantPromise, countriesPromise, languagesPromise, currenciesPromise]);

        if (tenantError) {
          console.error(`Error fetching tenant from core DB: ${tenantError.message}`);
          throw tenantError;
        }
        if (countriesError) throw countriesError;
        if (languagesError) throw languagesError;
        if (currenciesError) throw currenciesError;
        
        responseData = {
          tenant: tenantData,
          countries: countriesData,
          languages: languagesData,
          currencies: currenciesData,
        };
        break;
      }

      case 'update_tenant_slug': {
        const { slug } = payload;
        // The tenantId is already available from the authenticated user context
        responseData = await callRpc(supabaseAdmin, 'update_tenant_slug', {
          p_tenant_id: tenantId,
          p_slug: slug,
        });
        break;
      }

      case 'update_tenant_description': {
        const { description } = payload;
        if (description === undefined) throw new Error('Description is required.');
        responseData = await callRpc(supabaseAdmin, 'update_tenant_description', {
          p_tenant_id: tenantId,
          p_description: description,
        });
        break;
      }

      case 'check_slug_availability': {
        const { slug, countryId, platformId } = payload;
        if (!slug || !countryId || !platformId) throw new Error('Slug, Country ID, and Platform ID are required.');
        
        responseData = await callRpc(supabaseAdmin, 'check_slug_availability', {
          p_slug: slug,
          p_country_id: countryId,
          p_tenant_id: tenantId,
          p_platform_id: platformId,
        });
        break;
      }
      
      // --- OTHER ACTIONS ---
      case 'get_service_categories': {
        const { data, error } = await supabaseAdmin
          .from('service_categories')
          .select('*')
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .order('name');
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get_product_categories': {
        const { data, error } = await supabaseAdmin
          .from('product_categories')
          .select('*')
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .order('name');
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'create_service_category': {
        const { name, description } = payload;
        const { data, error } = await supabaseAdmin
          .from('service_categories')
          .insert([{ tenant_id: tenantId, platform_id: platformId, name, description, is_active: true }])
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'create_product_category': {
        const { name, description } = payload;
        const { data, error } = await supabaseAdmin
          .from('product_categories')
          .insert([{ tenant_id: tenantId, platform_id: platformId, name, description, is_active: true }])
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'update_service_category': {
        const { id, name, description } = payload;
        const { data, error } = await supabaseAdmin
          .from('service_categories')
          .update({ name, description })
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'update_product_category': {
        const { id, name, description } = payload;
        const { data, error } = await supabaseAdmin
          .from('product_categories')
          .update({ name, description })
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'delete_service_category': {
        const { id } = payload;
        const { error } = await supabaseAdmin
          .from('service_categories')
          .delete()
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId);
        if (error) throw error;
        responseData = { success: true };
        break;
      }

      case 'delete_product_category': {
        const { id } = payload;
        const { error } = await supabaseAdmin
          .from('product_categories')
          .delete()
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId);
        if (error) throw error;
        responseData = { success: true };
        break;
      }

      case 'toggle_service_category_status': {
        const { id, is_active } = payload;
        const { data, error } = await supabaseAdmin
          .from('service_categories')
          .update({ is_active })
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'toggle_product_category_status': {
        const { id, is_active } = payload;
        const { data, error } = await supabaseAdmin
          .from('product_categories')
          .update({ is_active })
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      // --- TREATMENT CATEGORIES ACTIONS ---
      case 'get_treatment_categories': {
        const { data, error } = await supabaseAdmin
          .from('treatment_categories')
          .select('*')
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .order('name');
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'create_treatment_category': {
        const { name, description } = payload;
        const { data, error } = await supabaseAdmin
          .from('treatment_categories')
          .insert([{ tenant_id: tenantId, platform_id: platformId, name, description, is_active: true }])
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'update_treatment_category': {
        const { id, name, description } = payload;
        const { data, error } = await supabaseAdmin
          .from('treatment_categories')
          .update({ name, description })
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'delete_treatment_category': {
        const { id } = payload;
        const { error } = await supabaseAdmin
          .from('treatment_categories')
          .delete()
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId);
        if (error) throw error;
        responseData = { success: true };
        break;
      }

      case 'toggle_treatment_category_status': {
        const { id, is_active } = payload;
        const { data, error } = await supabaseAdmin
          .from('treatment_categories')
          .update({ is_active })
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }
      
      case 'update_treatment_category_assignments': {
        const { treatment_id, category_ids } = payload;
        if (!treatment_id || !category_ids) {
          throw new Error('treatment_id and category_ids are required.');
        }
        const { error } = await supabaseAdmin.rpc('update_treatment_category_assignments', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_treatment_id: treatment_id,
          p_category_ids: category_ids,
        });
        if (error) throw error;
        responseData = { success: true };
        break;
      }

      case 'get_brands': {
        const { data, error } = await supabaseAdmin
          .from('product_brands')
          .select('*')
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .order('name');
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'create_brand': {
        const { name, description } = payload;
        const { data, error } = await supabaseAdmin
          .from('product_brands')
          .insert([{ tenant_id: tenantId, platform_id: platformId, name, description }])
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'update_brand': {
        const { id, name, description, is_active } = payload;
        const { data, error } = await supabaseAdmin
          .from('product_brands')
          .update({ name, description, is_active })
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'delete_brand': {
        const { id } = payload;
        const { error } = await supabaseAdmin
          .from('product_brands')
          .delete()
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId);
        if (error) throw error;
        responseData = { success: true };
        break;
      }

      case 'toggle_brand_status': {
        const { id, is_active } = payload;
        const { data, error } = await supabaseAdmin
          .from('product_brands')
          .update({ is_active })
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'create_supplier': {
        const { 
          name, document_type_id, identification_number, phone, email, branch_ids,
          address_line_1, address_line_2, city, state, postal_code, country 
        } = payload;
        
        const { data, error } = await supabaseAdmin
          .from('suppliers')
          .insert([{ 
            tenant_id: tenantId, 
            platform_id: platformId,
            name, 
            document_type_id, 
            identification_number, 
            phone, 
            email,
            branch_ids,
            address_line_1,
            address_line_2,
            city,
            state,
            postal_code,
            country,
            is_active: true 
          }])
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'update_supplier': {
        const { id, ...updates } = payload;

        // The single 'address' field is deprecated. It's handled by detailed fields.
        // This prevents errors if an old client sends the old field.
        if ('address' in updates) {
          delete updates.address;
        }

        const { data, error } = await supabaseAdmin
          .from('suppliers')
          .update(updates)
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }



      case 'create_purchase': {
        const { branch_id, supplier_id, purchase_date, total_amount, status, notes, items } = payload;

        if (!branch_id || !items || items.length === 0) {
          throw new Error('Branch ID and at least one item are required.');
        }

        // Fetch tenant settings for costing method
        const { data: tenantSettingsData, error: settingsError } = await supabaseAdmin
          .from('tenant_settings')
          .select('settings_data')
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .single();

        if (settingsError && settingsError.code !== 'PGRST116') { // PGRST116 means no rows found
          throw settingsError;
        }

        const costingMethod = tenantSettingsData?.settings_data?.costing_method || 'last_purchase'; // Default to last_purchase

        // Validación de sucursal del proveedor
        if (supplier_id) {
          const { data: supplier, error: supplierError } = await supabaseAdmin
            .from('suppliers')
            .select('branch_ids')
            .eq('id', supplier_id)
            .eq('tenant_id', tenantId)
            .eq('platform_id', platformId)
            .single();

          if (supplierError) throw new Error('Error al verificar el proveedor.');
          if (!supplier.branch_ids || !supplier.branch_ids.includes(branch_id)) {
            throw new Error('La sucursal de la compra no está permitida para este proveedor.');
          }
        }

        // 1. Create the purchase record
        const { data: purchase, error: purchaseError } = await supabaseAdmin
          .from('purchases')
          .insert({
            tenant_id: tenantId,
            platform_id: platformId,
            branch_id,
            supplier_id,
            purchase_date,
            total_amount,
            status,
            notes,
          })
          .select()
          .single();

        if (purchaseError) throw purchaseError;

        // 2. Create purchase items
        const purchaseItems = items.map((item: any) => ({
          purchase_id: purchase.id,
          tenant_id: tenantId,
          platform_id: platformId,
          product_id: item.product_id,
          quantity: item.quantity,
          cost_price: item.cost_price,
        }));

        const { error: itemsError } = await supabaseAdmin
          .from('purchase_items')
          .insert(purchaseItems);

        if (itemsError) {
          // Rollback purchase creation
          await supabaseAdmin.from('purchases').delete().eq('id', purchase.id).eq('tenant_id', tenantId).eq('platform_id', platformId);
          throw itemsError;
        }

        // 3. Update stock and cost price for each product in the branch
        for (const item of items) {
          const { data: branchProduct, error: fetchError } = await supabaseAdmin
            .from('branch_products')
            .select('id, stock_quantity, cost_price')
            .eq('branch_id', branch_id)
            .eq('product_id', item.product_id)
            .eq('tenant_id', tenantId)
            .eq('platform_id', platformId)
            .single();

          if (fetchError) {
            console.warn(`Product ${item.product_id} not found in branch ${branch_id}. Skipping stock update.`);
            continue;
          }

          // Determine costing method from tenant settings
          let newCost = item.cost_price; // Default to last-cost

          if (costingMethod === 'average' || costingMethod === 'ponderado') {
            const currentStock = branchProduct.stock_quantity || 0;
            const currentCost = branchProduct.cost_price || 0;
            const incomingQuantity = item.quantity;
            const incomingCost = item.cost_price;

            const totalQuantity = currentStock + incomingQuantity;

            if (totalQuantity > 0) {
              newCost = ((currentStock * currentCost) + (incomingQuantity * incomingCost)) / totalQuantity;
            } else {
              newCost = incomingCost;
            }
          }

          const newStock = (branchProduct.stock_quantity || 0) + item.quantity;

          const { error: updateError } = await supabaseAdmin
            .from('branch_products')
            .update({
              stock_quantity: newStock,
              cost_price: newCost,
            })
            .eq('id', branchProduct.id)
            .eq('tenant_id', tenantId)
            .eq('platform_id', platformId);

          if (updateError) {
            console.error(`Failed to update stock for product ${item.product_id} in branch ${branch_id}`, updateError);
          }
        }

        responseData = purchase;
        break;
      }

      case 'complete_purchase': {
        const { purchase_id } = payload;
        if (!purchase_id) {
          throw new Error('Purchase ID is required to complete a purchase.');
        }

        // 1. Fetch the purchase and its items
        const { data: purchase, error: fetchPurchaseError } = await supabaseAdmin
          .from('purchases')
          .select('*, items:purchase_items(*)')
          .eq('id', purchase_id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .single();

        if (fetchPurchaseError) throw fetchPurchaseError;
        if (purchase.status === 'completed') {
          throw new Error('La compra ya ha sido completada.');
        }

        // 2. Update stock and cost price for each product in the branch
        for (const item of purchase.items) {
          const { data: branchProduct, error: fetchBranchProductError } = await supabaseAdmin
            .from('branch_products')
            .select('id, stock_quantity, cost_price')
            .eq('branch_id', purchase.branch_id)
            .eq('product_id', item.product_id)
            .eq('tenant_id', tenantId)
            .eq('platform_id', platformId)
            .single();

          if (fetchBranchProductError) {
            console.warn(`Product ${item.product_id} not found in branch ${purchase.branch_id}. Skipping stock update for completed purchase.`);
            continue;
          }

          const newStock = (branchProduct.stock_quantity || 0) + item.quantity;
          const newCost = item.cost_price; // Use the cost from the purchase item

          const { error: updateError } = await supabaseAdmin
            .from('branch_products')
            .update({
              stock_quantity: newStock,
              cost_price: newCost,
            })
            .eq('id', branchProduct.id)
            .eq('tenant_id', tenantId)
            .eq('platform_id', platformId);

          if (updateError) {
            console.error(`Failed to update stock for product ${item.product_id} in branch ${purchase.branch_id} during completion.`, updateError);
          }
        }

        // 3. Update the purchase status to 'completed'
        const { data: updatedPurchase, error: updatePurchaseError } = await supabaseAdmin
          .from('purchases')
          .update({ status: 'completed' })
          .eq('id', purchase_id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .select()
          .single();

        if (updatePurchaseError) throw updatePurchaseError;

        responseData = updatedPurchase;
        break;
      }

      case 'get_purchases': {
        const { tenantId: requestedTenantId } = payload;
        if (!requestedTenantId) {
          throw new Error('Tenant ID is required for get_purchases.');
        }

        const { data, error } = await supabaseAdmin
          .from('purchases')
          .select(`
            *,
            supplier:supplier_id (name),
            branch:branch_id (name),
            items:purchase_items(*, product:product_id(name))
          `)
          .eq('tenant_id', requestedTenantId)
          .eq('platform_id', platformId)
          .order('purchase_date', { ascending: false });

        if (error) throw error;
        responseData = data;
        break;
      }

      case 'receive_purchase': {
        const { purchase_id, branch_id, received_items, reception_notes } = payload;
        if (!purchase_id || !branch_id || !received_items) {
          throw new Error('Purchase ID, Branch ID, and received items are required.');
        }
        const { data, error } = await supabaseAdmin.rpc('receive_purchase', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_purchase_id: purchase_id,
          p_branch_id: branch_id,
          p_received_items: received_items,
          p_reception_notes: reception_notes,
        });
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'cancel_purchase': {
        const { purchase_id } = payload;
        if (!purchase_id) {
          throw new Error('Purchase ID is required.');
        }
        const { data, error } = await supabaseAdmin.rpc('cancel_purchase', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_purchase_id: purchase_id,
        });
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'update_purchase_payment_status': {
        const { purchase_id, payment_status } = payload;
        if (!purchase_id || !payment_status) {
          throw new Error('Purchase ID and payment status are required.');
        }
        const { data, error } = await supabaseAdmin.rpc('update_purchase_payment_status', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_purchase_id: purchase_id,
          p_payment_status: payment_status,
        });
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'adjust_purchase_total': {
        const { purchase_id } = payload;
        if (!purchase_id) {
          throw new Error('Purchase ID is required.');
        }
        const { data, error } = await supabaseAdmin.rpc('adjust_purchase_total', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_purchase_id: purchase_id,
        });
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get_purchase_reception_details': {
        const { purchase_id } = payload;
        if (!purchase_id) {
          throw new Error('Purchase ID is required.');
        }
        const { data, error } = await supabaseAdmin.rpc('get_purchase_reception_details', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_purchase_id: purchase_id,
        });
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'create_product_transfer': {
        const { from_branch_id, to_branch_id, transfer_date, notes, items } = payload;
        if (!from_branch_id || !to_branch_id || !items || items.length === 0) {
          throw new Error('From Branch ID, To Branch ID and at least one item are required.');
        }
        const { data, error } = await supabaseAdmin.rpc('create_product_transfer', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_from_branch_id: from_branch_id,
          p_to_branch_id: to_branch_id,
          p_transfer_date: transfer_date,
          p_notes: notes,
          p_items: items,
        });
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'update_product_transfer_status': {
        const { transfer_id, status } = payload;
        if (!transfer_id || !status) {
          throw new Error('Transfer ID and status are required.');
        }
        const { data, error } = await supabaseAdmin.rpc('update_product_transfer_status', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_transfer_id: transfer_id,
          p_status: status,
        });
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get_product_transfers': {
        const { branchFilter, statusFilter } = payload;

        let query = supabaseAdmin
          .from('product_transfers')
          .select(`
            *,
            origin_branch:origin_branch_id (name),
            destination_branch:destination_branch_id (name),
            items:product_transfer_items(*, product:products(name))
          `)
          .eq('tenant_id', tenantId)

        if (branchFilter && branchFilter !== 'all') {
          query = query.or(`origin_branch_id.eq.${branchFilter},destination_branch_id.eq.${branchFilter}`);
        }

        if (statusFilter && statusFilter !== 'all') {
          query = query.eq('status', statusFilter);
        }

        const { data, error } = await query.order('transfer_date', { ascending: false });

        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get_tax_types': {
        const { data, error } = await supabaseAdmin
          .from('tax_types')
          .select('*')
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .order('name');
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'create_tax_type': {
        const { name, rate, is_percentage, is_active } = payload;
        const { data, error } = await supabaseAdmin
          .from('tax_types')
          .insert([{ tenant_id: tenantId, platform_id: platformId, name, rate, is_percentage, is_active }])
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'update_tax_type': {
        const { id, name, rate, is_percentage, is_active } = payload;
        const { data, error } = await supabaseAdmin
          .from('tax_types')
          .update({ name, rate, is_percentage, is_active })
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'delete_tax_type': {
        const { id } = payload;
        const { error } = await supabaseAdmin
          .from('tax_types')
          .delete()
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId);
        if (error) throw error;
        responseData = { success: true };
        break;
      }

      case 'add_product_tax_type': {
        const { product_id, tax_type_id } = payload;
        const { data, error } = await supabaseAdmin
          .from('product_tax_types')
          .insert([{ tenant_id: tenantId, platform_id: platformId, product_id, tax_type_id }])
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get_product_tax_types': {
        const { product_id } = payload;
        const { data, error } = await supabaseAdmin
          .from('product_tax_types')
          .select('*, tax_types(name, rate, is_percentage)')
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .eq('product_id', product_id);
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'remove_product_tax_type': {
        const { id } = payload;
        const { error } = await supabaseAdmin
          .from('product_tax_types')
          .delete()
          .eq('id', id)
          .eq('tenant_id', tenantId);
        if (error) throw error;
        responseData = { success: true };
        break;
      }

      case 'add_service_tax_type': {
        const { service_id, tax_type_id } = payload;
        const { data, error } = await supabaseAdmin
          .from('service_tax_types')
          .insert([{ tenant_id: tenantId, service_id, tax_type_id }])
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get_service_tax_types': {
        const { service_id } = payload;
        if (!service_id) {
          responseData = [];
          break;
        }
        const { data, error } = await supabaseAdmin
          .from('service_tax_types')
          .select('*, tax_types(name, rate, is_percentage)')
          .eq('tenant_id', tenantId)
          .eq('service_id', service_id);
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'remove_service_tax_type': {
        const { id } = payload;
        const { error } = await supabaseAdmin
          .from('service_tax_types')
          .delete()
          .eq('id', id)
          .eq('tenant_id', tenantId);
        if (error) throw error;
        responseData = { success: true };
        break;
      }

      case 'get_branches': {
        const { tenantId: requestedTenantId } = payload;
        if (!requestedTenantId) {
          throw new Error('Tenant ID is required for get_branches.');
        }
        const userAssignments = decodedToken.app_metadata?.assignments || [];
        const hasAccess = userAssignments.some( (assignment: any) => assignment.tenant_id === requestedTenantId);
        if (!hasAccess) {
          throw new Error('Acceso denegado: El usuario no tiene asignaciones para el tenant solicitado.');
        }
        const { data, error } = await supabaseAdmin.rpc('get_tenant_branches', { p_tenant_id: requestedTenantId, p_platform_id: platformId });
                if (error) throw error;
                responseData = data;
                break;
              }
        
              case 'get_branch_photos': {
                const { branchId } = payload;
                if (!branchId) throw new Error('Branch ID is required.');
                
                const { data, error } = await supabaseAdmin
                  .from('branch_photos')
                  .select('*')
                  .eq('tenant_id', tenantId)
                  .eq('platform_id', platformId)
                  .eq('branch_id', branchId)
                  .order('sort_order');
                  
                if (error) throw error;
                                        responseData = data;
                                        break;
                                      }
                                
                                      case 'upload_branch_photo': {
                                        const { branchId, fileBase64, fileName, fileSize, mimeType } = payload;
                                        if (!branchId || !fileBase64 || !fileName || !fileSize || !mimeType) {
                                          throw new Error('branchId, fileBase64, fileName, fileSize, and mimeType are required.');
                                        }
                                
                                        // 1. Upload file to Google Drive
                                        const { data: uploadData, error: uploadError } = await supabaseAdmin.functions.invoke('google-drive-upload', {
                                          body: {
                                            fileBase64,
                                            fileName,
                                            mimeType,
                                            uploadContext: 'BranchPhoto',
                                            contextId: branchId, // Use branchId to organize files in Drive
                                            tenantId,
                                            platformId,
                                            branchId,
                                            userId,
                                          },
                                        });
                                
                                        if (uploadError) throw new Error(`Google Drive upload failed: ${uploadError.message}`);
                                        const { fileId } = uploadData;
                                
                                        // 2. Check if it should be the primary photo
                                        const { count, error: countError } = await supabaseAdmin
                                          .from('branch_photos')
                                          .select('*', { count: 'exact', head: true })
                                          .eq('branch_id', branchId)
                                          .eq('tenant_id', tenantId)
                                          .eq('platform_id', platformId);
                                        
                                        if (countError) throw countError;
                                        const isFirstPhoto = count === 0;
                                
                                        // 3. Insert record into branch_photos table
                                        const { data: newPhoto, error: insertError } = await supabaseAdmin
                                          .from('branch_photos')
                                          .insert({
                                            branch_id: branchId,
                                            tenant_id: tenantId,
                                            platform_id: platformId,
                                            google_drive_file_id: fileId,
                                            file_name: fileName,
                                            file_size: fileSize,
                                            mime_type: mimeType,
                                            is_primary: isFirstPhoto,
                                          })
                                          .select()
                                          .single();
                                
                                        if (insertError) throw insertError;
                                
                                        responseData = newPhoto;
                                        break;
                                      }
                                
                                      case 'set_primary_branch_photo': {                                const { branchId, photoId } = payload;
                                if (!branchId || !photoId) throw new Error('Branch ID and Photo ID are required.');
                                
                                responseData = await callRpc(supabaseAdmin, 'set_primary_branch_photo', {
                                  p_tenant_id: tenantId,
                                  p_platform_id: platformId,
                                  p_branch_id: branchId,
                                  p_photo_id: photoId,
                                });
                                break;
                              }
                        
                              case 'delete_branch_photo': {                        const { branchId, photoId } = payload;
                        if (!branchId || !photoId) throw new Error('Branch ID and Photo ID are required.');
                
                        // 1. Call RPC to delete from DB and get the file ID
                        const google_drive_file_id = await callRpc(supabaseAdmin, 'delete_branch_photo', {
                          p_tenant_id: tenantId,
                          p_platform_id: platformId,
                          p_branch_id: branchId,
                          p_photo_id: photoId,
                        });
                
                        // 2. If successful, invoke edge function to delete from Google Drive (fire and forget)
                        if (google_drive_file_id) {
                          supabaseAdmin.functions.invoke('google-drive-delete', {
                            body: {
                              fileId: google_drive_file_id,
                              tenantId: tenantId,
                              platformId: platformId,
                              uploadContext: 'BranchPhoto', // Context for GDrive credentials
                            }
                          });
                        }
                        
                        responseData = { success: true, deleted_file_id: google_drive_file_id };
                        break;
                      }
                
                      case 'delete-branch': {        const { p_branch_id } = payload;
        const { data, error } = await supabaseAdmin.rpc('delete_branch', { p_tenant_id: tenantId, p_platform_id: platformId, p_branch_id });
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'archive-branch': {
        const { p_branch_id } = payload;
        const { data, error } = await supabaseAdmin.rpc('archive_branch', { p_tenant_id: tenantId, p_platform_id: platformId, p_branch_id });
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'activate-branches-batch': {
        const { p_branch_ids } = payload;
        if (!p_branch_ids || !Array.isArray(p_branch_ids) || p_branch_ids.length === 0) {
            throw new Error('p_branch_ids must be a non-empty array.');
        }

        // 1. Get current active branches count (Services DB)
        const { count: currentActiveCount, error: countError } = await supabaseAdmin
            .from('branches')
            .select('*', { count: 'exact', head: true })
            .eq('tenant_id', tenantId)
            .eq('platform_id', platformId)
            .eq('status', 'active');

        if (countError) {
            throw new Error(`Error counting active branches: ${countError.message}`);
        }

        // 2. Call Billing RPC in Core
        const { data: billingResult, error: billingError } = await coreSupabase.rpc('process_branch_activation_billing', {
            p_tenant_id: tenantId,
            p_platform_id: platformId,
            p_quantity_to_activate: p_branch_ids.length,
            p_current_active_count: currentActiveCount || 0
        });

        if (billingError) {
            throw new Error(`Billing validation failed: ${billingError.message}`);
        }

        if (!billingResult.success) {
            // Return specific error structure for Frontend to handle (e.g. show upsell modal)
            responseData = { success: false, error: billingResult };
            break; 
        }

        // 3. Activate Branches locally (Services DB)
        const { data: activatedBranches, error: activateError } = await supabaseAdmin
            .from('branches')
            .update({ status: 'active', activated_at: new Date().toISOString() })
            .in('id', p_branch_ids)
            .eq('tenant_id', tenantId)
            .eq('platform_id', platformId)
            .select();

        if (activateError) {
            console.error('CRITICAL: Billing authorized but local activation failed.', activateError);
            throw new Error(`Error activating branches: ${activateError.message}`);
        }

        responseData = { 
            success: true, 
            activated_count: activatedBranches.length,
            billing_details: billingResult 
        };
        break;
      }

      case 'calculate_batch_activation_proration': {
        const { branchIds } = payload;
        if (!branchIds || branchIds.length === 0) {
          throw new Error('Branch IDs are required for proration calculation.');
        }
        
        const { data, error } = await supabaseAdmin.rpc('calculate_batch_activation_proration', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_branch_ids: branchIds,
        });

        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get_users_for_tenant': {
        const { tenantId: requestedTenantId } = payload;
        if (!requestedTenantId) throw new Error('Tenant ID is required for get_users_for_tenant.');
        
        const userAssignments = decodedToken.app_metadata?.assignments || [];
        const hasAccess = userAssignments.some( (assignment: any) => assignment.tenant_id === requestedTenantId);
        if (!hasAccess) {
          throw new Error('Acceso denegado: El usuario no tiene asignaciones para el tenant solicitado.');
        }

        const { data, error } = await supabaseAdmin.rpc('get_tenant_users', { 
          p_target_tenant_id: requestedTenantId,
          p_platform_id: platformId
        });

        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get_tenant_roles': {
        const { tenantId: requestedTenantId } = payload;
        if (!requestedTenantId) throw new Error('Tenant ID is required for get_tenant_roles.');

          const { data, error } = await supabaseAdmin
            .from('roles')
            .select('id, name, display_name') // Select specific columns
            .eq('platform_id', platformId) // Filter by current platform
            .or(`tenant_id.is.null,tenant_id.eq.${requestedTenantId}`) // Global roles or tenant-specific roles
            .like('name', 'tenant_%') // Add the like filter
            .order('name');

        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get_sales_settings': {
        if (!tenantId) throw new Error('Tenant ID is required.');
        const { data, error } = await supabaseAdmin
          .from('tenant_settings')
          .select('settings_data')
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .single();

        if (error && error.code !== 'PGRST116') throw error; // PGRST116 means no rows found, which is fine.
        responseData = data?.settings_data?.sales_settings || {};
        break;
      }

      case 'update_sales_settings': {
        const { settings } = payload;
        if (!tenantId || settings === undefined) throw new Error('Tenant ID and settings payload are required.');

        // Fetch current settings to merge with new sales_settings
        const { data: currentSettings, error: fetchError } = await supabaseAdmin
          .from('tenant_settings')
          .select('settings_data')
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .single();

        if (fetchError && fetchError.code !== 'PGRST116') throw fetchError; // PGRST116 means no rows found, which is fine.

        const newSettingsData = {
          ...(currentSettings?.settings_data || {}),
          sales_settings: settings
        };

        const { data, error } = await supabaseAdmin
          .from('tenant_settings')
          .upsert({ 
            tenant_id: tenantId, 
            platform_id: platformId, 
            settings_data: newSettingsData 
          }, { onConflict: 'tenant_id, platform_id' })
          .select()
          .single();

        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get_managed_tvs': {
        const { data, error } = await supabaseAdmin.rpc('get_managed_tvs', { 
          p_tenant_id: tenantId,
          p_platform_id: platformId
        });
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get_media_playlists': {
        const { data, error } = await supabaseAdmin
          .from('media_playlists')
          .select('*')
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId);
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'delete_media_playlist': {
        const { playlist_id } = payload;
        if (!playlist_id) throw new Error('Playlist ID is required.');
        const { error } = await supabaseAdmin
          .from('media_playlists')
          .delete()
          .eq('id', playlist_id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId);
        if (error) throw error;
        responseData = { success: true };
        break;
      }

      case 'create_media_playlist': {
        const { name, description } = payload;
        if (!name) throw new Error('Playlist name is required.');
        const { data, error } = await supabaseAdmin
          .from('media_playlists')
          .insert({ name, description, tenant_id: tenantId, platform_id: platformId })
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'update_media_playlist': {
        const { playlist_id, name, description } = payload;
        if (!playlist_id) throw new Error('Playlist ID is required.');
        const { data, error } = await supabaseAdmin
          .from('media_playlists')
          .update({ name, description })
          .eq('id', playlist_id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'delete_playlist_item': {
        const { item_id } = payload;
        if (!item_id) throw new Error('Playlist item ID is required.');

        // Security check: Ensure the item belongs to a playlist of the current tenant/platform
        const { data: itemData, error: itemError } = await supabaseAdmin
          .from('playlist_items')
          .select('id, media_playlists(tenant_id, platform_id)')
          .eq('id', item_id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .single();

        if (itemError) throw new Error('Failed to verify playlist item ownership.');
        if (itemData.media_playlists.tenant_id !== tenantId || itemData.media_playlists.platform_id !== platformId) {
          throw new Error('Permission denied: You do not own this playlist item.');
        }

        const { error: deleteError } = await supabaseAdmin
          .from('playlist_items')
          .delete()
          .eq('id', item_id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId);
        if (deleteError) throw deleteError;
        responseData = { success: true };
        break;
      }

      case 'update_playlist_items_order': {
        const { items_to_update } = payload;
        if (!items_to_update || items_to_update.length === 0) {
          throw new Error('Items to update are required.');
        }

        // Security check: Ensure the items belong to a playlist of the current tenant
        const firstItemId = items_to_update[0].id;
        const { data: itemData, error: itemError } = await supabaseAdmin
          .from('playlist_items')
          .select('id, media_playlists(tenant_id, platform_id)')
          .eq('id', firstItemId)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .single();
        
        if (itemError) throw new Error('Failed to verify playlist ownership for reordering.');
        if (itemData.media_playlists.tenant_id !== tenantId || itemData.media_playlists.platform_id !== platformId) {
          throw new Error('Permission denied: You do not own this playlist.');
        }

        const { error: rpcError } = await supabaseAdmin.rpc('update_playlist_items_order', { 
          p_tenant_id: tenantId, 
          p_platform_id: platformId, 
          items_to_update 
        });
        if (rpcError) throw rpcError;
        responseData = { success: true };
        break;
      }

      // --- PUBLIC/SEMI-PUBLIC ACTIONS ---
      case 'get_playlist_items': {
        const { p_playlist_id } = payload;
        if (!p_playlist_id) throw new Error('Playlist ID is required.');

        // Step 1: Verify the playlist belongs to the tenant.
        const { data: playlistData, error: playlistError } = await supabaseAdmin
          .from('media_playlists')
          .select('id')
          .eq('id', p_playlist_id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .single();

        if (playlistError) throw playlistError;
        if (!playlistData) throw new Error('Playlist not found or access denied.');

        // Step 2: Fetch the items for the verified playlist.
        const { data, error } = await supabaseAdmin
          .from('playlist_items')
          .select('*')
          .eq('playlist_id', p_playlist_id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .order('item_order', { ascending: true });

        if (error) throw error;
        responseData = data;
        break;
      }

      case 'add_playlist_item': {
        const { playlist_id, media_url } = payload;
        if (!playlist_id || !media_url) {
          throw new Error('Playlist ID and media URL are required.');
        }

        // Security Check: Ensure the playlist belongs to the tenant.
        const { data: playlistData, error: playlistError } = await supabaseAdmin
          .from('media_playlists')
          .select('id')
          .eq('id', playlist_id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .single();

        if (playlistError) throw playlistError;
        if (!playlistData) throw new Error('Playlist not found or access denied.');

        const { data: functionData, error: functionError } = await supabaseAdmin.functions.invoke('resolve-youtube-playlist', { body: { videoUrl: media_url } });
        if (functionError) throw functionError;

        const { videos } = functionData;
        if (!videos || videos.length === 0) {
          responseData = { success: false, message: 'Video no encontrado' };
          break;
        }

        if (videos.length > 1) {
          responseData = { needs_confirmation: true, videos: videos };
          break;
        }

        const video = videos[0];

        const { data: maxOrderData, error: maxOrderError } = await supabaseAdmin
          .from('playlist_items')
          .select('item_order')
          .eq('playlist_id', playlist_id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .order('item_order', { ascending: false })
          .limit(1)
          .single();

        if (maxOrderError && maxOrderError.code !== 'PGRST116') throw maxOrderError;

        const newItemOrder = maxOrderData ? maxOrderData.item_order + 1 : 1;

        const { data: newItem, error: insertError } = await supabaseAdmin
          .from('playlist_items')
          .insert({
            playlist_id: playlist_id,
            tenant_id: tenantId,
            platform_id: platformId,
            media_url: video.videoUrl,
            media_type: 'youtube',
            item_order: newItemOrder,
            video_title: video.title,
            duration_seconds: video.durationSeconds
          })
          .select()
          .single();

        if (insertError) throw insertError;

        responseData = { success: true, newItem: newItem };
        break;
      }

      case 'import_playlist_items': {
        const { playlist_id, videos } = payload;
        if (!playlist_id || !videos || videos.length === 0) {
          throw new Error('Playlist ID and videos are required.');
        }

        // Security Check
        const { data: playlistData, error: playlistError } = await supabaseAdmin
          .from('media_playlists')
          .select('id')
          .eq('id', playlist_id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .single();
        if (playlistError) throw playlistError;
        if (!playlistData) throw new Error('Playlist not found or access denied.');

        // Get starting order
        const { data: maxOrderData, error: maxOrderError } = await supabaseAdmin
          .from('playlist_items')
          .select('item_order')
          .eq('playlist_id', playlist_id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .order('item_order', { ascending: false })
          .limit(1)
          .single();
        if (maxOrderError && maxOrderError.code !== 'PGRST116') throw maxOrderError;
        
        const startingOrder = maxOrderData ? maxOrderData.item_order + 1 : 1;

        const newItems = videos.map((video: any, index: number) => ({
          playlist_id: playlist_id,
          tenant_id: tenantId,
          platform_id: platformId,
          media_url: video.videoUrl,
          media_type: 'youtube',
          item_order: startingOrder + index,
          video_title: video.title,
          duration_seconds: video.durationSeconds
        }));

        const { error: insertError } = await supabaseAdmin.from('playlist_items').insert(newItems);
        if (insertError) throw insertError;

        responseData = { success: true, inserted: newItems.length };
        break;
      }

      case 'assign_playlist_to_tv': {
        const { tv_display_id, playlist_id } = payload;
        if (!tv_display_id) {
          throw new Error('TV Display ID is required.');
        }

        // Security Check: Ensure the tv_display belongs to the tenant.
        const { data: tvData, error: tvError } = await supabaseAdmin
          .from('tv_displays')
          .select('id')
          .eq('id', tv_display_id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .single();

        if (tvError) throw tvError;
        if (!tvData) throw new Error('TV Display not found or access denied.');

        // If a playlist_id is provided, also check that it belongs to the tenant.
        if (playlist_id) {
          const { data: playlistData, error: playlistError } = await supabaseAdmin
            .from('media_playlists')
            .select('id')
            .eq('id', playlist_id)
            .eq('tenant_id', tenantId)
            .eq('platform_id', platformId)
            .single();
          
          if (playlistError) throw playlistError;
          if (!playlistData) throw new Error('Playlist not found or access denied.');
        }

        // Perform the update
        const { data, error } = await supabaseAdmin
          .from('tv_displays')
          .update({ media_playlist_id: playlist_id })
          .eq('id', tv_display_id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .select()
          .single();

        if (error) throw error;
        responseData = data;
        break;
      }



      case 'get_tenant_storage_usage': {
        const { tenantId: requestedTenantId } = payload;
        if (!requestedTenantId) throw new Error('Tenant ID is required for get_tenant_storage_usage.');

        // Get storage usage and limit from subscription details
        const subscriptionUsage = await _getSubscriptionUsageDetails(supabaseAdmin, requestedTenantId);
        const storageAsset = subscriptionUsage.usage.find(u => u.asset_purpose_key === 'storage');
        
        const totalSize = storageAsset ? storageAsset.used : 0;
        const storageLimit = storageAsset ? storageAsset.limit : 0;
        const breakdown = storageAsset ? storageAsset.breakdown : [];

        responseData = { totalSize, storageLimit, breakdown };
        break;
      }

      case 'GET_NOTIFICATIONS': {
        const { page = 1, pageSize = 20 } = payload;
        const from = (page - 1) * pageSize;
        const to = from + pageSize - 1;

        const { data, error, count } = await supabaseClient
          .from('notifications')
          .select('*', { count: 'exact' })
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .order('created_at', { ascending: false })
          .range(from, to);

        if (error) {
          console.error('Error fetching notifications:', error);
          throw new Error(`Failed to fetch notifications: ${error.message}`);
        }
        
        responseData = { data, count };
        break;
      }

      case 'MARK_NOTIFICATION_AS_READ': {
        const { notification_id } = payload;
        if (!notification_id) throw new Error('Notification ID is required.');

        const { data, error } = await supabaseClient
          .from('notifications')
          .update({ read_at: new Date().toISOString() })
          .eq('id', notification_id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .select()
          .single();

        if (error) {
          console.error('Error marking notification as read:', error);
          throw new Error(`Failed to mark notification as read: ${error.message}`);
        }

        responseData = data;
        break;
      }

      case 'MARK_ALL_NOTIFICATIONS_AS_READ': {
        const { data, error } = await supabaseClient
          .from('notifications')
          .update({ read_at: new Date().toISOString() })
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .is('read_at', null) // Solo actualiza las no leídas
          .select();

        if (error) {
          console.error('Error marking all notifications as read:', error);
          throw new Error(`Failed to mark all notifications as read: ${error.message}`);
        }

        responseData = { success: true, updatedCount: data.length };
        break;
      }

      case 'get_chatter_events': {
        const { resource_type, resource_id } = payload;
        if (!resource_type || !resource_id) {
          throw new Error('resource_type and resource_id are required.');
        }

        // Step 1: Call the simplified SQL function to get raw events
        const { data: rawEvents, error: rpcError } = await supabaseClient.rpc('get_unified_chatter_feed', {
          p_resource_type: resource_type,
          p_resource_id: resource_id
        });

        if (rpcError) {
          console.error('Error fetching raw chatter feed:', rpcError);
          throw new Error(`Failed to fetch raw chatter feed: ${rpcError.message}`);
        }

        if (!rawEvents || rawEvents.length === 0) {
          responseData = [];
          break;
        }

        // Step 2: Fetch attachments for all comments
        const commentIds = rawEvents.filter((e: any) => e.event_type === 'comment').map((e: any) => e.id);
        const { data: attachments, error: attachmentsError } = await supabaseAdmin
          .from('chatter_attachments')
          .select('*')
          .in('chatter_comment_id', commentIds)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId);

        if (attachmentsError) {
          console.error('Error fetching chatter attachments:', attachmentsError);
          // Don't throw, just continue without attachments
        }

        const attachmentsByCommentId = (attachments || []).reduce((acc: any, attachment: any) => {
          if (!acc[attachment.chatter_comment_id]) {
            acc[attachment.chatter_comment_id] = [];
          }
          acc[attachment.chatter_comment_id].push(attachment);
          return acc;
        }, {});

        // Step 3: Collect unique user IDs
        const userIds = [...new Set(rawEvents.map((event: any) => event.user_id).filter(Boolean))];

        // Step 4: Fetch user profiles using admin client and create a map
        const userProfiles = new Map();
        if (userIds.length > 0) {
          const { data: { users }, error: usersError } = await supabaseAdmin.auth.admin.listUsers({ page: 1, perPage: 9999 });
          
          if (usersError) {
            console.error('Chatter enrichment failed: Could not list users.', usersError);
          } else {
            for (const id of userIds) {
              const user = users.find(u => u.id === id);
              if (user) {
                const fullName = `${user.user_metadata?.first_name || ''} ${user.user_metadata?.last_name || ''}`.trim();
                userProfiles.set(id, {
                  user_full_name: fullName || user.email,
                  user_avatar_url: user.user_metadata?.avatar_url || null
                });
              }
            }
          }
        }

        // Step 5: Enrich events with user data and attachments
        const enrichedEvents = rawEvents.map((event: any) => {
          const profile = event.user_id ? userProfiles.get(event.user_id) : null;
          return {
            ...event,
            user_full_name: profile?.user_full_name || (event.user_id ? 'Usuario Desconocido' : 'Sistema'),
            user_avatar_url: profile?.user_avatar_url || null,
            chatter_attachments: attachmentsByCommentId[event.id] || [],
          };
        });

        responseData = enrichedEvents;
        break;
      }

      case 'create_chatter_comment': {
        const { resource_type, resource_id, text } = payload;
        if (!resource_type || !resource_id || !text) {
          throw new Error('resource_type, resource_id, and text are required.');
        }

        const { data, error } = await supabaseClient
          .from('chatter_comments') // Corrected table
          .insert({
            tenant_id: tenantId,
            platform_id: platformId,
            user_id: userId,
            resource_type: resource_type,
            resource_id: resource_id,
            comment_text: text // Corrected column
          })
          .select() // Simplified select
          .single();

        if (error) {
          console.error('Error creating chatter comment:', error);
          // The original error from Supabase is often more informative
          throw new Error(error.message || 'Failed to create chatter comment');
        }

        responseData = data;
        break;
      }

      case 'CREATE_MENTION_NOTIFICATIONS': {
        const { mentioned_user_ids, actor_name, resource_type, resource_id, comment_snippet } = payload;
        if (!mentioned_user_ids || !actor_name || !resource_type || !resource_id) {
          throw new Error('Missing required payload for mention notifications.');
        }

        const notificationPromises = mentioned_user_ids.map((userId: string) => {
          return createUserNotification(
            supabaseAdmin,
            tenantId,
            userId,
            'mention',
            `${actor_name} te ha mencionado en un comentario.`,
            comment_snippet,
                        `/app/${resource_type}/${resource_id}`          );
        });

        await Promise.all(notificationPromises);
        responseData = { success: true };
        break;
      }


      case 'get_document_types': {
        const { applies_to } = payload;
        if (!applies_to) throw new Error('applies_to is required.');

        const { data, error } = await supabaseAdmin
          .from('document_types')
          .select('*')
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .contains('applies_to', [applies_to])
          .order('name');

        if (error) throw error;
        responseData = data;
        break;
      }

      case 'create_document_type': {
        const { name, abbreviation, applies_to } = payload;
        if (!name || !applies_to) throw new Error('name and applies_to are required.');

        const { data, error } = await supabaseAdmin
          .from('document_types')
          .insert({ tenant_id: tenantId, platform_id: platformId, name, abbreviation, applies_to, is_active: true })
          .select()
          .single();
        
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'update_document_type': {
        const { id, ...updates } = payload;
        if (!id) throw new Error('ID is required for update.');

        const { data, error } = await supabaseAdmin
          .from('document_types')
          .update(updates)
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .select()
          .single();

        if (error) throw error;
        responseData = data;
        break;
      }

      case 'delete_document_type': {
        const { id } = payload;
        if (!id) throw new Error('ID is required for delete.');

        const { error } = await supabaseAdmin
          .from('document_types')
          .delete()
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId);

        if (error) throw error;
        responseData = { success: true };
        break;
      }

      case 'get_tenant_settings': {
        if (!tenantId || !platformId) throw new Error('Tenant ID or Platform ID not found in JWT.');
        
        const { data, error } = await supabaseAdmin
          .from('tenant_settings')
          .select('settings_data')
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .single();

        if (error && error.code !== 'PGRST116') {
          throw error;
        }
        
        const settingsData = data?.settings_data || {};

        // Define default image settings
        const defaultImageSettings = {
          catalogo: { maxSizeMB: 1.0, maxWidthOrHeight: 1920 },
          evidencias: { maxSizeMB: 2.0, maxWidthOrHeight: 2048 },
          firmas: { maxSizeMB: 0.5, maxWidthOrHeight: 1024 }
        };

        // Ensure image_compression_settings exists and is complete
        if (!settingsData.image_compression_settings) {
          settingsData.image_compression_settings = defaultImageSettings;
        } else {
          // Check for partial configurations and fill missing parts
          for (const key of Object.keys(defaultImageSettings) as Array<keyof typeof defaultImageSettings>) {
            if (!settingsData.image_compression_settings[key]) {
              settingsData.image_compression_settings[key] = defaultImageSettings[key];
            }
          }
        }
        
        responseData = { settings_data: settingsData };
        break;
      }

      case 'update_image_compression_settings': {
        const { newImageSettings } = payload;
        if (!tenantId || !platformId) throw new Error('Tenant ID or Platform ID not found in JWT.');
        if (!newImageSettings) throw new Error('newImageSettings are required.');

        // 1. Fetch current settings
        const { data: currentSettings, error: fetchError } = await supabaseAdmin
          .from('tenant_settings')
          .select('settings_data')
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .single();

        if (fetchError && fetchError.code !== 'PGRST116') {
          throw fetchError;
        }

        const currentData = currentSettings?.settings_data || {};

        // 2. Deep merge the new settings
        const mergedSettings = {
          ...currentData,
          image_compression_settings: {
            ...(currentData.image_compression_settings || {}),
            ...newImageSettings,
          },
        };

        // 3. Upsert the merged settings
        const { data, error } = await supabaseAdmin
          .from('tenant_settings')
          .upsert(
            { tenant_id: tenantId, platform_id: platformId, settings_data: mergedSettings },
            { onConflict: 'tenant_id, platform_id' }
          )
          .select('settings_data')
          .single();

        if (error) throw error;
        responseData = { settings_data: data?.settings_data };
        break;
      }

      case 'update_tenant_settings': {
        const { tenantId: queryTenantId, platformId: queryPlatformId, newSettings } = payload;
        if (!queryTenantId) throw new Error('Tenant ID is required for update_tenant_settings.');
        if (!queryPlatformId) throw new Error('Platform ID is required for update_tenant_settings.');
        if (!newSettings) throw new Error('New settings are required for update_tenant_settings.');
        
        const { data: currentSettings, error: fetchError } = await supabaseAdmin
          .from('tenant_settings')
          .select('settings_data')
          .eq('tenant_id', queryTenantId)
          .eq('platform_id', queryPlatformId)
          .single();

        if (fetchError && fetchError.code !== 'PGRST116') {
          throw fetchError;
        }

        const mergedSettings = { ...currentSettings?.settings_data, ...newSettings };
        
        const { data, error } = await supabaseAdmin
          .from('tenant_settings')
          .upsert({ 
            tenant_id: queryTenantId, 
            platform_id: queryPlatformId, 
            settings_data: mergedSettings 
          }, { onConflict: 'tenant_id, platform_id' })
          .select('settings_data')
          .single();

        if (error) throw error;
        responseData = { settings_data: data?.settings_data };
        break;
      }

      case 'get_notification_settings': {
        if (!tenantId) throw new Error('Tenant ID is required.');
        const { data, error } = await supabaseAdmin
            .from('tenant_template_settings')
            .select('template_type, is_active')
            .eq('tenant_id', tenantId)
            .eq('platform_id', platformId);

        if (error) throw error;
        responseData = data;
        break;
      }

      case 'update_notification_settings': {
        const { settings } = payload;
        if (!settings || !Array.isArray(settings)) {
            throw new Error('Settings payload must be an array.');
        }
        if (!tenantId) throw new Error('Tenant ID is required.');

        const upsertData = settings.map(s => ({
            tenant_id: tenantId,
            platform_id: platformId,
            template_type: s.template_type,
            is_active: s.is_active
        }));

        const { data, error } = await supabaseAdmin
            .from('tenant_template_settings')
            .upsert(upsertData, { onConflict: 'tenant_id, platform_id, template_type' })
            .select();

        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get_suppliers': {
        const { data, error } = await supabaseAdmin
          .from('suppliers')
          .select('*, document_types(name)')
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .order('name');
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get_supplier': {
        const { id } = payload;
        if (!id) throw new Error('Supplier ID is required.');
        const { data, error } = await supabaseAdmin
          .from('suppliers')
          .select('*')
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .eq('id', id)
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }





      case 'toggle_supplier_status': {
        const { id, is_active } = payload;
        const { data, error } = await supabaseAdmin
          .from('suppliers')
          .update({ is_active })
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get_supplier_contacts': {
        const { supplierId } = payload;
        if (!supplierId) throw new Error('Supplier ID is required.');
        const { data, error } = await supabaseAdmin
          .from('supplier_contacts')
          .select(`
            *,
            contact_types ( name )
          `)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .eq('supplier_id', supplierId)
          .order('created_at');
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'create_supplier_contact': {
        const { supplier_id, contact_type_id, name, email, phone } = payload;
        if (!supplier_id || !contact_type_id || !name) {
          throw new Error('Supplier ID, contact type ID, and name are required.');
        }
        const { data, error } = await supabaseAdmin
          .from('supplier_contacts')
          .insert([{ tenant_id: tenantId, platform_id: platformId, supplier_id, contact_type_id, name, email, phone }])
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'update_supplier_contact': {
        const { id, ...updates } = payload;
        if (!id) throw new Error('Contact ID is required.');
        const { data, error } = await supabaseAdmin
          .from('supplier_contacts')
          .update(updates)
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'delete_supplier_contact': {
        const { id } = payload;
        if (!id) throw new Error('Contact ID is required.');
        const { error } = await supabaseAdmin
          .from('supplier_contacts')
          .delete()
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId);
        if (error) throw error;
        responseData = { success: true };
        break;
      }

      case 'get_supplier_addresses': {
        const { supplierId } = payload;
        if (!supplierId) throw new Error('Supplier ID is required.');
        const { data, error } = await supabaseAdmin
          .from('supplier_addresses')
          .select('*')
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .eq('supplier_id', supplierId)
          .order('created_at');
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'create_supplier_address': {
        const { supplier_id, ...addressData } = payload;
        if (!supplier_id) throw new Error('Supplier ID is required.');
        const { data, error } = await supabaseAdmin
          .from('supplier_addresses')
          .insert([{ tenant_id: tenantId, platform_id: platformId, supplier_id, ...addressData }])
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'update_supplier_address': {
        const { id, ...updates } = payload;
        if (!id) throw new Error('Address ID is required.');
        const { data, error } = await supabaseAdmin
          .from('supplier_addresses')
          .update(updates)
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'delete_supplier_address': {
        const { id } = payload;
        if (!id) throw new Error('Address ID is required.');
        const { error } = await supabaseAdmin
          .from('supplier_addresses')
          .delete()
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId);
        if (error) throw error;
        responseData = { success: true };
        break;
      }

      // --- EXPENSE PROVIDER ACTIONS ---
      case 'list-expense-providers': {
        const { filters } = payload;
        let query = supabaseAdmin
          .from('expense_providers')
          .select('*, document_types(name)')
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId);

        if (filters) {
          if (!filters.showInactive) {
            query = query.eq('is_active', true);
          }
          if (filters.searchTerm) {
            const searchTerm = `%${filters.searchTerm}%`;
            query = query.or(`name.ilike.${searchTerm},identification_number.ilike.${searchTerm}`);
          }
        }

        const { data, error } = await query.order('name');
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get-expense-provider': {
        const { id } = payload;
        if (!id) throw new Error('Expense Provider ID is required.');
        const { data, error } = await supabaseAdmin
          .from('expense_providers')
          .select('*')
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .eq('id', id)
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'create-expense-provider': {
        const { 
          name, document_type_id, identification_number, phone, email,
          address_line_1, address_line_2, city, state, postal_code, country 
        } = payload;
        
        const { data, error } = await supabaseAdmin
          .from('expense_providers')
          .insert([{ 
            tenant_id: tenantId, 
            platform_id: platformId,
            name, 
            document_type_id, 
            identification_number, 
            phone, 
            email,
            address_line_1,
            address_line_2,
            city,
            state,
            postal_code,
            country,
            is_active: true 
          }])
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'update-expense-provider': {
        const { id, ...updates } = payload;
        if (!id) throw new Error('Expense Provider ID is required.');
        const { data, error } = await supabaseAdmin
          .from('expense_providers')
          .update(updates)
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'delete-expense-provider': {
        const { id } = payload;
        if (!id) throw new Error('Expense Provider ID is required.');
        const { error } = await supabaseAdmin
          .from('expense_providers')
          .delete()
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId);
        if (error) throw error;
        responseData = { success: true };
        break;
      }

      case 'toggle-expense-provider-status': {
        const { id, is_active } = payload;
        if (!id || is_active === undefined) throw new Error('ID and is_active status are required.');
        const { data, error } = await supabaseAdmin
          .from('expense_providers')
          .update({ is_active })
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get-expense-provider-contacts': {
        const { providerId } = payload;
        if (!providerId) throw new Error('Expense Provider ID is required.');
        const { data, error } = await supabaseAdmin
          .from('expense_provider_contacts')
          .select('*, contact_types ( name )')
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .eq('expense_provider_id', providerId)
          .order('created_at');
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'create-expense-provider-contact': {
        const { expense_provider_id, contact_type_id, name, email, phone } = payload;
        if (!expense_provider_id || !contact_type_id || !name) {
          throw new Error('Provider ID, contact type ID, and name are required.');
        }
        const { data, error } = await supabaseAdmin
          .from('expense_provider_contacts')
          .insert([{ tenant_id: tenantId, platform_id: platformId, expense_provider_id, contact_type_id, name, email, phone }])
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'update-expense-provider-contact': {
        const { id, ...updates } = payload;
        if (!id) throw new Error('Contact ID is required.');
        const { data, error } = await supabaseAdmin
          .from('expense_provider_contacts')
          .update(updates)
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'delete-expense-provider-contact': {
        const { id } = payload;
        if (!id) throw new Error('Contact ID is required.');
        const { error } = await supabaseAdmin
          .from('expense_provider_contacts')
          .delete()
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId);
        if (error) throw error;
        responseData = { success: true };
        break;
      }

      case 'get-expense-provider-addresses': {
        const { providerId } = payload;
        if (!providerId) throw new Error('Expense Provider ID is required.');
        const { data, error } = await supabaseAdmin
          .from('expense_provider_addresses')
          .select('*')
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .eq('expense_provider_id', providerId)
          .order('created_at');
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'create-expense-provider-address': {
        const { expense_provider_id, ...addressData } = payload;
        if (!expense_provider_id) throw new Error('Provider ID is required.');
        const { data, error } = await supabaseAdmin
          .from('expense_provider_addresses')
          .insert([{ tenant_id: tenantId, platform_id: platformId, expense_provider_id, ...addressData }])
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'update-expense-provider-address': {
        const { id, ...updates } = payload;
        if (!id) throw new Error('Address ID is required.');
        const { data, error } = await supabaseAdmin
          .from('expense_provider_addresses')
          .update(updates)
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'delete-expense-provider-address': {
        const { id } = payload;
        if (!id) throw new Error('Address ID is required.');
        const { error } = await supabaseAdmin
          .from('expense_provider_addresses')
          .delete()
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId);
        if (error) throw error;
        responseData = { success: true };
        break;
      }

      // --- EXPENSE ACTIONS ---
      case 'list-expenses': {
        const { filters } = payload; // filters: { dateRange, status, branchId, providerId }
        
        let query = supabaseAdmin
          .from('expenses')
          .select(`
            *,
            expense_providers (name),
            branches (name)
          `)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId);

        if (filters?.status && filters.status !== 'all') {
          query = query.eq('status', filters.status);
        }
        if (filters?.branchId && filters.branchId !== 'all') {
          query = query.eq('branch_id', filters.branchId);
        }
        if (filters?.providerId && filters.providerId !== 'all') {
          query = query.eq('expense_provider_id', filters.providerId);
        }
        if (filters?.dateRange?.from) {
          query = query.gte('expense_date', filters.dateRange.from);
        }
        if (filters?.dateRange?.to) {
          query = query.lte('expense_date', filters.dateRange.to);
        }

        const { data, error } = await query.order('expense_date', { ascending: false });

        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get-expense': {
        const { id } = payload;
        if (!id) throw new Error('Expense ID is required.');
        const { data, error } = await supabaseAdmin
          .from('expenses')
          .select(`
            *,
            expense_providers (*),
            branches (*)
          `)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .eq('id', id)
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'create-expense': {
        const { expenseData } = payload;
        if (!expenseData) throw new Error('Expense data is required.');
        const { data, error } = await supabaseAdmin
          .from('expenses')
          .insert({ ...expenseData, tenant_id: tenantId, platform_id: platformId })
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'update-expense': {
        const { id, ...updates } = payload;
        if (!id) throw new Error('Expense ID is required.');
        const { data, error } = await supabaseAdmin
          .from('expenses')
          .update(updates)
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'delete-expense': {
        const { id } = payload;
        if (!id) throw new Error('Expense ID is required.');
        const { error } = await supabaseAdmin
          .from('expenses')
          .delete()
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId);
        if (error) throw error;
        responseData = { success: true };
        break;
      }

      // --- RECURRING EXPENSE ACTIONS ---
      case 'list-recurring-expenses': {
        const { filters } = payload; // filters: { status, branchId, providerId, isActive }

        let query = supabaseAdmin
          .from('recurring_expenses')
          .select(`
            *,
            expense_providers (name),
            branches (name)
          `)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId);

        if (filters?.status && filters.status !== 'all') {
          query = query.eq('status', filters.status);
        }
        if (filters?.branchId && filters.branchId !== 'all') {
          query = query.eq('branch_id', filters.branchId);
        }
        if (filters?.providerId && filters.providerId !== 'all') {
          query = query.eq('expense_provider_id', filters.providerId);
        }
        if (filters?.isActive !== undefined && filters.isActive !== 'all') {
          query = query.eq('is_active', filters.isActive);
        }

        const { data, error } = await query.order('start_date', { ascending: false });

        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get-recurring-expense': {
        const { id } = payload;
        if (!id) throw new Error('Recurring Expense ID is required.');
        const { data, error } = await supabaseAdmin
          .from('recurring_expenses')
          .select(`
            *,
            expense_providers (*),
            branches (*)
          `)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .eq('id', id)
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'create-recurring-expense': {
        const { recurringExpenseData } = payload;
        if (!recurringExpenseData) throw new Error('Recurring Expense data is required.');
        const { data, error } = await supabaseAdmin
          .from('recurring_expenses')
          .insert([{ ...recurringExpenseData, tenant_id: tenantId, platform_id: platformId }])
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'update-recurring-expense': {
        const { id, ...updates } = payload;
        if (!id) throw new Error('Recurring Expense ID is required.');
        const { data, error } = await supabaseAdmin
          .from('recurring_expenses')
          .update(updates)
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'delete-recurring-expense': {
        const { id } = payload;
        if (!id) throw new Error('Recurring Expense ID is required.');
        const { error } = await supabaseAdmin
          .from('recurring_expenses')
          .delete()
          .eq('id', id)
          .eq('tenant_id', tenantId);
        if (error) throw error;
        responseData = { success: true };
        break;
      }

      case 'toggle-recurring-expense-status': {
        const { id, is_active } = payload;
        if (!id || is_active === undefined) throw new Error('ID and is_active status are required.');
        const { data, error } = await supabaseAdmin
          .from('recurring_expenses')
          .update({ is_active })
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get_contact_types': {
        const { applies_to } = payload || {};
        let query = supabaseAdmin
          .from('contact_types')
          .select('*')
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId);

        if (applies_to === 'supplier') {
          query = query.eq('is_for_supplier', true);
        } else if (applies_to === 'client') {
          query = query.eq('is_for_client', true);
        }

        const { data, error } = await query.order('name');
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'create_contact_type': {
        const { name, is_for_supplier, is_for_client } = payload;
        if (!name) throw new Error('Name is required.');
        const { data, error } = await supabaseAdmin
          .from('contact_types')
          .insert([{ tenant_id: tenantId, platform_id: platformId, name, is_for_supplier, is_for_client }])
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'update_contact_type': {
        const { id, ...updates } = payload;
        if (!id) throw new Error('ID is required.');
        const { data, error } = await supabaseAdmin
          .from('contact_types')
          .update(updates)
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'delete_contact_type': {
        const { id } = payload;
        if (!id) throw new Error('ID is required.');
        const { error } = await supabaseAdmin
          .from('contact_types')
          .delete()
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId);
        if (error) throw error;
        responseData = { success: true };
        break;
      }

      case 'get_supplier_products': {
        const { supplierId } = payload;
        let query = supabaseAdmin
          .from('supplier_products')
          .select(`
            *,
            products:product_id (*),
            suppliers:supplier_id (*)
          `);
        query = query.eq('tenant_id', tenantId).eq('platform_id', platformId);
        if (supplierId) {
          query = query.eq('supplier_id', supplierId);
        }
        const { data, error } = await query.order('created_at', { ascending: false });
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get_regional_settings_data': {
        const { data: countriesData, error: countriesError } = await supabaseAdmin
          .rpc('get_countries_with_timezones');

        if (countriesError) {
          throw new Error(`Error fetching countries: ${countriesError.message}`);
        }

        const { data: localizationsData, error: localizationsError } = await supabaseAdmin
          .from('languages')
          .select('*')
          .order('name');

        if (localizationsError) {
          throw new Error(`Error fetching localizations: ${localizationsError.message}`);
        }

        const { data: currenciesData, error: currenciesError } = await supabaseAdmin
          .from('currencies')
          .select('*')
          .order('name');

        if (currenciesError) {
          throw new Error(`Error fetching currencies: ${currenciesError.message}`);
        }

        responseData = {
          countries: countriesData,
          localizations: localizationsData,
          currencies: currenciesData,
        };
        break;
      }

      case 'add_supplier_product': {
        const { supplier_id, product_id, supplier_price } = payload;
        if (!supplier_id || !product_id || supplier_price === undefined) {
          throw new Error('Supplier ID, Product ID, and Supplier Price are required.');
        }
        const { data, error } = await supabaseAdmin
          .from('supplier_products')
          .insert([{ 
            tenant_id: tenantId, 
            platform_id: platformId,
            supplier_id, 
            product_id, 
            supplier_price,
            is_active: true
          }])
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'update_supplier_product': {
        const { id, supplier_price, is_active } = payload;
        if (!id || supplier_price === undefined) {
          throw new Error('Supplier Product ID and Supplier Price are required.');
        }
        const updates: { supplier_price: number; is_active?: boolean } = { supplier_price };
        if (is_active !== undefined) {
          updates.is_active = is_active;
        }
        const { data, error } = await supabaseAdmin
          .from('supplier_products')
          .update(updates)
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'toggle_supplier_product_status': {
        const { id, is_active } = payload;
        if (!id || is_active === undefined) {
          throw new Error('Supplier Product ID and active status are required.');
        }
        const { data, error } = await supabaseAdmin
          .from('supplier_products')
          .update({ is_active })
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get_master_services': {
        const { searchTerm, showInactive, categoryId } = payload;
        const { data, error } = await supabaseAdmin.rpc('search_services', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_search_term: searchTerm || '',
          p_show_inactive: showInactive || false,
          p_category_id: categoryId || null,
        });
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get_master_products': {
        const { searchTerm, showInactive, categoryId, brandId } = payload;
        const { data, error } = await supabaseAdmin.rpc('search_products', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_search_term: searchTerm || null,
          p_show_inactive: showInactive || false,
          p_category_id: categoryId === '' ? null : (categoryId || null),
          p_brand_id: brandId === '' ? null : (brandId || null),
        });
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'create_master_service': {
        const { serviceData } = payload;
        const { data, error } = await supabaseAdmin
          .from('services')
          .insert([{ ...serviceData, tenant_id: tenantId, platform_id: platformId }])
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'create_master_product': {
        const { productData } = payload;
        const { data, error } = await supabaseAdmin
          .from('products')
          .insert([{ ...productData, tenant_id: tenantId, platform_id: platformId }])
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'update_master_service': {
        const { id, updates } = payload;
        const { data, error } = await supabaseAdmin
          .from('services')
          .update(updates)
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get_master_service_details': {
        const { serviceId } = payload;
        if (!serviceId) throw new Error('Service ID is required.');

        const { data, error } = await supabaseAdmin
          .from('services')
          .select('*') // Seleccionar todos los campos
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .eq('id', serviceId)
          .single();

        if (error) throw error;
        responseData = data;
        break;
      }

      case 'update_master_product': {
        const { id, updates } = payload;
        
        // Remove category fields before updating to prevent errors
        // Category assignments are handled by a separate action.
        if (updates.category) {
          delete updates.category;
        }
        if (updates.product_categories) {
          delete updates.product_categories;
        }

        const { data, error } = await supabaseAdmin
          .from('products')
          .update(updates)
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'update_product_category_assignments': {
        const { product_id, category_ids } = payload;
        if (!product_id || !category_ids) {
          throw new Error('product_id and category_ids are required.');
        }
        const { error } = await supabaseAdmin.rpc('update_product_category_assignments', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_product_id: product_id,
          p_category_ids: category_ids,
        });
        if (error) throw error;
        responseData = { success: true };
        break;
      }

      case 'get_branch_services': {
        const { branchId } = payload;
        if (!branchId) throw new Error('Branch ID is required.');

        const userRole = decodedToken.app_metadata?.assignments?.[0]?.role_name;

        let query = supabaseAdmin
          .from('branch_services')
          .select(`
            *,
            service:service_id (*)
          `)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)

        if (branchId === 'all' && userRole !== 'tenant_super_admin') {
          const userBranchId = decodedToken.app_metadata?.assignments?.[0]?.branch_id;
          if (userBranchId) {
            query = query.eq('branch_id', userBranchId);
          } else {
            // Handle case where user has no branch_id, maybe return empty array
            responseData = [];
            break;
          }
        } else if (branchId !== 'all') {
          query = query.eq('branch_id', branchId);
        }

        const { data, error } = await query;

        if (error) throw error;

        if (branchId === 'all' && userRole === 'tenant_super_admin') {
          const serviceIds = new Set();
          const uniqueServices = data.filter((item: any) => {
            if (!serviceIds.has(item.service_id)) {
              serviceIds.add(item.service_id);
              return true;
            }
            return false;
          });
          responseData = uniqueServices.map((item: any) => ({
            id: item.service_id,
            branch_service_id: item.id,
            name: item.service?.name,
            description: item.service?.description,
            duration_minutes: item.service?.duration_minutes,
            selling_price: item.selling_price,
            is_branch_active: item.is_active,
          }));
        } else {
          responseData = data.map((item: any) => ({
            id: item.service_id,
            branch_service_id: item.id,
            name: item.service?.name,
            description: item.service?.description,
            duration_minutes: item.service?.duration_minutes,
            selling_price: item.selling_price,
            is_branch_active: item.is_active,
          }));
        }
        break;
      }

      case 'get_branch_products': {
        const { branchId, searchTerm } = payload;
        let query = supabaseAdmin
          .from('branch_products')
          .select(`
            id,
            is_active,
            selling_price,
            stock_quantity,
            branch_id,
            product:products!inner(id, name, sku, barcode, is_active),
            branch:branches(name)
          `)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .eq('is_active', true) // Solo productos activos en la sucursal
          .eq('product.is_active', true); // Solo productos maestros activos

        if (branchId && branchId !== 'all') {
          query = query.eq('branch_id', branchId);
        }

        if (searchTerm) {
          const filterString = `name.ilike.%${searchTerm}%,sku.ilike.%${searchTerm}%,barcode.ilike.%${searchTerm}%`;
          query = query.or(filterString, { foreignTable: 'products' });
        }

        const { data, error } = await query.limit(50);

        if (error) throw error;

        responseData = data.map((item: any) => ({
          ...item.product,
          branch_product_id: item.id,
          is_branch_active: item.is_active,
          selling_price: item.selling_price,
          stock_quantity: item.stock_quantity,
          branch_name: item.branch?.name,
          id: item.product.id,
        }));
        break;
      }

      case 'assign_service_to_branch': {
        const { service_id, branch_ids, defaults } = payload;
        if (!service_id || !branch_ids || !defaults) throw new Error('Missing required payload for assignment.');
        const assignments = branch_ids.map((branch_id: string) => ({
          service_id,
          branch_id,
          tenant_id: tenantId,
          platform_id: platformId,
          selling_price: defaults.selling_price,
          duration_minutes: defaults.duration_minutes,
          is_active: defaults.is_active ?? true,
        }));
        const { data, error } = await supabaseAdmin.from('branch_services').insert(assignments).select();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'assign_product_to_branch': {
        const { product_id, branch_ids, defaults } = payload;
        if (!product_id || !branch_ids || !defaults) throw new Error('Missing required payload for assignment.');
        const assignments = branch_ids.map((branch_id: string) => ({
          product_id,
          branch_id,
          tenant_id: tenantId,
          platform_id: platformId,
          selling_price: defaults.selling_price,
          stock_quantity: defaults.stock_quantity,
          is_active: defaults.is_active ?? true,
        }));
        const { data, error } = await supabaseAdmin.from('branch_products').insert(assignments).select();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'update_branch_service': {
        const { id, updates } = payload;
        const { data, error } = await supabaseAdmin
          .from('branch_services')
          .update(updates)
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'update_branch_product': {
        const { id, updates } = payload;
        const { data, error } = await supabaseAdmin
          .from('branch_products')
          .update(updates)
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'remove_service_from_branch': {
        const { branch_service_id } = payload;
        const { error } = await supabaseAdmin
          .from('branch_services')
          .delete()
          .eq('id', branch_service_id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId);
        if (error) throw error;
        responseData = { success: true };
        break;
      }

      case 'remove_product_from_branch': {
        const { branch_product_id } = payload;
        const { error } = await supabaseAdmin
          .from('branch_products')
          .delete()
          .eq('id', branch_product_id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId);
        if (error) throw error;
        responseData = { success: true };
        break;
      }

      case 'get_service_branch_prices': {
        const { serviceId } = payload;
        if (!serviceId) throw new Error('Service ID is required for get_service_branch_prices.');

        const { data, error } = await supabaseAdmin
          .from('branch_services')
          .select(`
            id,
            branch_id,
            selling_price,
            duration_minutes,
            is_active,
            is_visible_on_microsite,
            branches(name)
          `)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .eq('service_id', serviceId);

        if (error) throw error;
        responseData = data.map((item: any) => ({
          branch_service_id: item.id,
          branch_id: item.branch_id,
          branch_name: item.branches?.name,
          selling_price: item.selling_price,
          duration_minutes: item.duration_minutes,
          is_active: item.is_active,
          is_visible_on_microsite: item.is_visible_on_microsite,
        }));
        break;
      }

      case 'get_service_commissions_by_service_and_branch': {
        const { serviceId, branchId } = payload;
        if (!serviceId || !branchId) throw new Error('Service ID and Branch ID are required.');
        const { data: commissions, error: commissionsError } = await supabaseAdmin
          .from('service_user_commissions')
          .select(`*,
            services(id, name, price)
          `) // Removed users selection
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .eq('service_id', serviceId)
          .eq('branch_id', branchId)
          .order('created_at', { ascending: false });
        if (commissionsError) throw commissionsError;

        // Fetch all users for the tenant using the RPC
        const users = await callRpc(supabaseAdmin, 'get_tenant_users', { p_target_tenant_id: tenantId, p_platform_id: platformId });
        const usersMap = new Map(users.map((user: any) => [user.user_id, user]));

        responseData = commissions.map((commission: any) => ({
          ...commission,
          user: usersMap.get(commission.user_id) || null, // Enrich with user data
        }));
        break;
      }

      case 'get_product_commissions_by_product_and_branch': {
        const { productId, branchId } = payload;
        if (!productId || !branchId) throw new Error('Product ID and Branch ID are required.');
        const { data: commissions, error: commissionsError } = await supabaseAdmin
          .from('product_user_commissions')
          .select(`*,
            products(id, name, price)
          `) // Removed users selection
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .eq('product_id', productId)
          .eq('branch_id', branchId)
          .order('created_at', { ascending: false });
        if (commissionsError) throw commissionsError;

        // Fetch all users for the tenant using the RPC
        const users = await callRpc(supabaseAdmin, 'get_tenant_users', { p_target_tenant_id: tenantId, p_platform_id: platformId });
        const usersMap = new Map(users.map((user: any) => [user.user_id, user]));

        responseData = commissions.map((commission: any) => ({
          ...commission,
          user: usersMap.get(commission.user_id) || null, // Enrich with user data
        }));
        break;
      }

      case 'get_product_branch_prices': {
        const { productId } = payload;
        if (!productId) throw new Error('Product ID is required for get_product_branch_prices.');

        const { data, error } = await supabaseAdmin
          .from('branch_products')
          .select(`
            id,
            branch_id,
            selling_price,
            stock_quantity,
            is_active,
            branches(name)
          `)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .eq('product_id', productId);

        if (error) throw error;
        responseData = data.map((item: any) => ({
          branch_product_id: item.id,
          branch_id: item.branch_id,
          branch_name: item.branches?.name,
          selling_price: item.selling_price,
          stock_quantity: item.stock_quantity,
          is_active: item.is_active,
        }));
        break;
      }

      // --- UNITS OF MEASURE (UOM) ACTIONS ---
      case 'MANAGE_UOM': {
        const { operation, uomData } = payload;
        if (!operation) throw new Error('Operation is required for MANAGE_UOM.');

        switch (operation) {
          case 'GET':
            responseData = await callRpc(supabaseAdmin, 'get_units_of_measure', { p_tenant_id: tenantId, p_platform_id: platformId });
            break;
          case 'CREATE':
            if (!uomData || !uomData.name || !uomData.abbreviation) {
              throw new Error('Name and abbreviation are required to create a unit of measure.');
            }
            responseData = await callRpc(supabaseAdmin, 'create_unit_of_measure', {
              p_tenant_id: tenantId,
              p_platform_id: platformId,
              p_name: uomData.name,
              p_abbreviation: uomData.abbreviation,
            });
            break;
          case 'UPDATE':
            if (!uomData || !uomData.id || !uomData.name || !uomData.abbreviation) {
              throw new Error('ID, name, and abbreviation are required to update a unit of measure.');
            }
            responseData = await callRpc(supabaseAdmin, 'update_unit_of_measure', {
              p_id: uomData.id,
              p_tenant_id: tenantId,
              p_platform_id: platformId,
              p_name: uomData.name,
              p_abbreviation: uomData.abbreviation,
            });
            break;
          case 'DELETE':
            if (!uomData || !uomData.id) {
              throw new Error('ID is required to delete a unit of measure.');
            }
            responseData = await callRpc(supabaseAdmin, 'delete_unit_of_measure', {
              p_id: uomData.id,
              p_tenant_id: tenantId,
              p_platform_id: platformId,
            });
            break;
          default:
            throw new Error(`Invalid operation for MANAGE_UOM: ${operation}`);
        }
        break;
      }

      case 'get_client_settings': {
        const { data, error } = await supabaseAdmin
          .from('tenant_client_settings')
          .select('*')
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .single();

        if (error && error.code !== 'PGRST116') { // Ignorar si no se encuentra la fila
          throw error;
        }
        responseData = data;
        break;
      }

      case 'update_client_settings': {
        const { settings } = payload;
        if (!settings) throw new Error('Settings payload is required.');

        const { data, error } = await supabaseAdmin
          .from('tenant_client_settings')
          .upsert({ ...settings, tenant_id: tenantId, platform_id: platformId }, { onConflict: 'tenant_id, platform_id' })
          .select()
          .single();

        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get_document_templates': {
        const { data, error } = await supabaseAdmin
          .from('client_document_templates')
          .select('id, name, description, schema, is_active, version, fill_on_attention')
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .order('name');

        if (error) throw error;
        responseData = data;
        break;
      }

      case 'create_document_template': {
        const { name, description, schema } = payload;
        if (!name) throw new Error('Template name is required.');

        const { data, error } = await supabaseAdmin
          .from('client_document_templates')
          .insert([{ tenant_id: tenantId, platform_id: platformId, name, description, schema: schema || {} }])
          .select();

        if (error) throw error;
        responseData = data?.[0]; // Devolver el primer (y único) objeto creado
        break;
      }

      case 'update_document_template': {
        const { id, updates } = payload;
        if (!id || !updates) throw new Error('Template ID and updates are required.');

        const { data, error } = await supabaseAdmin
          .from('client_document_templates')
          .update(updates)
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .select();

        if (error) throw error;
        responseData = data?.[0]; // Devolver el primer (y único) objeto actualizado
        break;
      }

      case 'toggle_document_template_status': {
        const { id, is_active } = payload;
        if (id === undefined || is_active === undefined) throw new Error('Template ID and status are required.');

        const { data, error } = await supabaseAdmin
          .from('client_document_templates')
          .update({ is_active })
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .select()
          .single();

        if (error) throw error;
        responseData = data;
        break;
      }

      case 'save_client_document_instance': {
        const { client_id, template_id, data: formData, attention_id } = payload;
        if (!client_id || !template_id || !formData) throw new Error('Client ID, Template ID, and form data are required.');

        const { data, error } = await supabaseAdmin
          .from('client_document_instances')
          .insert([{ tenant_id: tenantId, platform_id: platformId, client_id, template_id, data: formData, attention_id: attention_id || null }])
          .select();

        if (error) throw error;

        await AuditService.logChange(supabaseAdmin, getCoreSupabaseClient(), {
          tenantId,
          userId: payload.current_user_id || 'System',
          action: 'INSERT',
          table: 'client_document_instances',
          recordId: data[0].id,
          newRecord: data[0]
        });

        responseData = data?.[0];
        break;
      }

            case 'get_client_document_instances': {
              const { client_id, attention_id } = payload;
              if (!client_id) throw new Error('Client ID is required.');
      
              let query = supabaseAdmin
                .from('client_document_instances')
                .select('*, template:template_id(name, description, version, schema)')
                .eq('tenant_id', tenantId)
                .eq('platform_id', platformId)
                .order('created_at', { ascending: false });
      
              if (client_id) {
                query = query.eq('client_id', client_id);
              }
      
              if (attention_id) {
                query = query.eq('attention_id', attention_id);
              }
      
              const { data, error } = await query;
      
              if (error) throw error;
              responseData = data;
              break;
            }
      

      case 'save_client_consent_record': {
        const { client_id, consent_type, signature_data, metadata } = payload;
        if (!client_id || !consent_type) throw new Error('Client ID and consent type are required.');

        const { data, error } = await supabaseAdmin
          .from('client_consent_records')
          .insert([{ tenant_id: tenantId, platform_id: platformId, client_id, consent_type, signature_data, metadata }])
          .select();

        if (error) throw error;

        await AuditService.logChange(supabaseAdmin, getCoreSupabaseClient(), {
          tenantId,
          userId: payload.current_user_id || 'System',
          action: 'INSERT',
          table: 'client_consent_records',
          recordId: data[0].id,
          newRecord: data[0]
        });

        responseData = data?.[0];
        break;
      }

      case 'get_client_consent_records': {
        const { client_id } = payload;
        if (!client_id) throw new Error('Client ID is required.');

        const { data, error } = await supabaseAdmin
          .from('client_consent_records')
          .select('*')
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .eq('client_id', client_id)
          .order('created_at', { ascending: false });

        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get_user_time_off_history': {
        const { userId, statusFilter, typeFilter, dateRange, branchId, searchTerm } = payload;
        const { data, error } = await supabaseAdmin.rpc('get_user_time_off_history', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_user_id: userId || null,
          p_status_filter: statusFilter || null,
          p_type_filter: typeFilter || null,
          p_date_range_start: dateRange?.from ? new Date(dateRange.from).toISOString().split('T')[0] : null,
          p_date_range_end: dateRange?.to ? new Date(dateRange.to).toISOString().split('T')[0] : null,
          p_branch_id: branchId || null,
          p_search_term: searchTerm || null,
        });
        if (error) throw error;
        responseData = data;
        break;
      }

      // --- EQUIPMENT BRAND ACTIONS ---
      case 'get_equipment_brands': {
        console.log('DEBUG: get_equipment_brands - Inicio');
        const startTime = performance.now();

        const { data, error } = await supabaseAdmin
          .from('equipment_brands')
          .select('*')
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .order('name');

        const queryEndTime = performance.now();
        console.log(`DEBUG: get_equipment_brands - Consulta a DB finalizada en ${queryEndTime - startTime} ms`);

        if (error) {
          console.error('DEBUG: get_equipment_brands - Error en consulta:', error);
          throw error;
        }

        const responseEndTime = performance.now();
        console.log(`DEBUG: get_equipment_brands - Preparación de respuesta finalizada en ${responseEndTime - queryEndTime} ms`);

        responseData = data;
        console.log('DEBUG: get_equipment_brands - Fin');
        break;
      }

      case 'create_equipment_brand': {
        const { name, description } = payload;
        if (!name) throw new Error('Equipment brand name is required.');
        const { data, error } = await supabaseAdmin
          .from('equipment_brands')
          .insert([{ tenant_id: tenantId, platform_id: platformId, name, description, is_active: true }])
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'update_equipment_brand': {
        const { id, ...updates } = payload;
        if (!id) throw new Error('Equipment brand ID is required.');
        const { data, error } = await supabaseAdmin
          .from('equipment_brands')
          .update(updates)
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'delete_equipment_brand': {
        const { id } = payload;
        if (!id) throw new Error('Equipment brand ID is required.');
        const { error } = await supabaseAdmin
          .from('equipment_brands')
          .delete()
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId);
        if (error) throw error;
        responseData = { success: true };
        break;
      }

      // --- EQUIPMENT TYPE ACTIONS ---
      case 'get_equipment_types': {
        responseData = await callRpc(supabaseAdmin, 'get_equipment_types', { p_tenant_id: tenantId, p_platform_id: platformId });
        break;
      }

      case 'create_equipment_type': {
        const { name, description } = payload;
        if (!name) throw new Error('Equipment type name is required.');
        responseData = await callRpc(supabaseAdmin, 'create_equipment_type', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_name: name,
          p_description: description,
        });
        break;
      }

      case 'update_equipment_type': {
        const { id, name, description, is_active } = payload;
        if (!id || !name) throw new Error('Equipment type ID and name are required.');
        responseData = await callRpc(supabaseAdmin, 'update_equipment_type', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_type_id: id,
          p_name: name,
          p_description: description,
          p_is_active: is_active,
        });
        break;
      }

      case 'delete_equipment_type': {
        const { id } = payload;
        if (!id) throw new Error('Equipment type ID is required.');
        responseData = await callRpc(supabaseAdmin, 'delete_equipment_type', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_type_id: id,
        });
        break;
      }

      // --- EQUIPMENT ACTIONS ---
      case 'get_equipment': {
        const { searchTerm, showInactive, typeId, brandId } = payload;
        responseData = await callRpc(supabaseAdmin, 'get_equipment', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_search_term: searchTerm || null,
          p_show_inactive: showInactive || false,
          p_type_id: typeId || null,
          p_brand_id: brandId || null,
        });
        break;
      }

      case 'create_equipment': {
        const { equipmentData } = payload;
        const { data, error } = await supabaseAdmin.rpc('create_equipment', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_equipment_data: equipmentData,
        });
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'update_equipment': {
        const { equipmentId, equipmentData } = payload;
        const { data, error } = await supabaseAdmin.rpc('update_equipment', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_equipment_id: equipmentId,
          p_equipment_data: equipmentData,
        });
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'delete_equipment': {
        const { equipmentId } = payload;
        const { data, error } = await supabaseAdmin.rpc('delete_equipment', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_equipment_id: equipmentId,
        });
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get_equipment_assignments': {
        const { equipmentId } = payload;
        const { data, error } = await supabaseAdmin.rpc('get_equipment_assignments', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_equipment_id: equipmentId,
        });
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get_user_assigned_equipment': {
        const { p_user_id } = payload;
        if (!p_user_id) {
          throw new Error('User ID is required.');
        }

        const { data, error } = await supabaseAdmin
          .from('equipment_assignments')
          .select(`
            assignment_id:id,
            equipment_id,
            equipment ( name )
          `)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .eq('user_id', p_user_id)
          .is('return_date', null);

        if (error) throw error;

        responseData = data.map((item: any) => ({
          assignment_id: item.assignment_id,
          equipment_id: item.equipment_id,
          equipment_name: item.equipment.name
        }));
        break;
      }

      case 'assign_equipment_to_user': {
        const { equipmentId, userId, branchId, assignmentDate } = payload;
        const { data, error } = await supabaseAdmin.rpc('assign_equipment_to_user', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_equipment_id: equipmentId,
          p_user_id: userId,
          p_branch_id: branchId,
          p_assignment_date: assignmentDate,
        });
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'return_equipment': {
        const { assignmentId, returnDate } = payload;
        const { data, error } = await supabaseAdmin.rpc('return_equipment', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_assignment_id: assignmentId,
          p_return_date: returnDate,
        });
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get_equipment_maintenance_history': {
        const { equipmentId } = payload;
        const { data, error } = await supabaseAdmin.rpc('get_equipment_maintenance_history', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_equipment_id: equipmentId,
        });
        if (error) throw error;
        responseData = data;
        break;
      }

            // --- PAYMENT METHODS ACTIONS ---
            case 'get_payment_methods': {
              const { data, error } = await supabaseAdmin
                .from('payment_methods')
                .select('*')
                .eq('tenant_id', tenantId)
                .eq('platform_id', platformId)
                .order('name');
              if (error) throw error;
              responseData = data;
              break;
            }
      
            case 'create_payment_method': {
              const { name, is_active, requires_evidence } = payload;
              const { data, error } = await supabaseAdmin
                .from('payment_methods')
                .insert([{ tenant_id: tenantId, platform_id: platformId, name, is_active, requires_evidence }])
                .select()
                .single();
              if (error) throw error;
              responseData = data;
              break;
            }
      
            case 'update_payment_method': {
              const { id, ...updates } = payload;
              const { data, error } = await supabaseAdmin
                .from('payment_methods')
                .update(updates)
                .eq('id', id)
                .eq('tenant_id', tenantId)
                .eq('platform_id', platformId)
                .select()
                .single();
              if (error) throw error;
              responseData = data;
              break;
            }
      
                      case 'delete_payment_method': {
                        const { id } = payload;
                        const { error } = await supabaseAdmin
                          .from('payment_methods')
                          .delete()
                          .eq('id', id)
                          .eq('tenant_id', tenantId)
                          .eq('platform_id', platformId);
                        if (error) throw error;
                        responseData = { success: true };
                        break;
                      }
            
                                          case 'get_document_sequences': {
                                            if (!tenantId) {
                                              throw new Error('Tenant ID is required.');
                                            }
                                            const { data, error } = await supabaseAdmin
                                              .from('document_sequences')
                                              .select('*')
                                              .eq('tenant_id', tenantId)
                                              .eq('platform_id', platformId)
                                              .order('name');
                                    
                                            if (error) throw error;
                                            responseData = data;
                                            break;
                                          }
                                
                                          case 'create_document_sequence': {
                                            const { sequenceData } = payload;
                                            if (!sequenceData) {
                                              throw new Error('Sequence data is required.');
                                            }
                                            const { data, error } = await supabaseAdmin
                                              .from('document_sequences')
                                              .insert({ ...sequenceData, tenant_id: tenantId, platform_id: platformId })
                                              .select()
                                              .single();
                                            
                                            if (error) throw error;
                                            responseData = data;
                                            break;
                                          }
                                
                                          case 'update_document_sequence': {
                                            const { sequenceId, updates } = payload;
                                            if (!sequenceId || !updates) {
                                              throw new Error('Sequence ID and updates are required.');
                                            }
                                            const { data, error } = await supabaseAdmin
                                              .from('document_sequences')
                                              .update(updates)
                                              .eq('id', sequenceId)
                                              .eq('tenant_id', tenantId)
                                              .eq('platform_id', platformId)
                                              .select()
                                              .single();
                                
                                            if (error) throw error;
                                            responseData = data;
                                            break;
                                          }
                                
                                          case 'delete_document_sequence': {
                                            const { sequenceId } = payload;
                                            if (!sequenceId) {
                                              throw new Error('Sequence ID is required.');
                                            }
                                            const { error } = await supabaseAdmin
                                              .from('document_sequences')
                                              .delete()
                                              .eq('id', sequenceId)
                                              .eq('tenant_id', tenantId)
                                              .eq('platform_id', platformId);
                                
                                            if (error) throw error;
                                            responseData = { success: true };
                                            break;
                                          }
                      
                          case 'get_stock_by_date': {
                            const { branchId, reportDate } = payload;
                            if (!branchId || !reportDate) {
                              throw new Error('Branch ID and Report Date are required.');
                            }
                            const { data, error } = await supabaseAdmin.rpc('get_stock_snapshot', {
                              p_tenant_id: tenantId,
                              p_platform_id: platformId,
                              p_branch_id: branchId,
                              p_report_date: reportDate,
                            });
                
                            if (error) throw error;
                            responseData = data;
                            break;
                          }
                
              case 'get_product_kardex': {
                const { productId, branchId } = payload;
                if (!productId || !branchId) {
                  throw new Error('Product ID and Branch ID are required.');
                }
                const { data, error } = await supabaseAdmin
                  .from('product_movements')
                  .select('*, products(name, sku)')
                  .eq('tenant_id', tenantId)
                  .eq('platform_id', platformId)
                  .eq('branch_id', branchId)
                  .eq('product_id', productId)
                  .order('movement_date', { ascending: false });
    
                if (error) throw error;
                responseData = data;
                break;
              }

              case 'get_sale_by_attention_id': {
                const { attentionId } = payload;
                if (!attentionId) {
                  throw new Error('Attention ID is required.');
                }
                const { data, error } = await supabaseAdmin
                  .from('sales')
                  .select('id')
                  .eq('attention_id', attentionId)
                  .eq('tenant_id', tenantId)
                  .eq('platform_id', platformId)
                  .single();

                if (error) {
                  throw new Error(`Error fetching sale by attention ID: ${error.message}`);
                }
                responseData = data;
                break;
              }

              case 'get_sale_details': {
                const { saleId } = payload;
                if (!saleId) {
                  throw new Error('Sale ID is required.');
                }

                // 1. Get Sale Details and Tenant Name in parallel
                const salePromise = supabaseAdmin
                  .from('sales')
                  .select(`
                    *,
                    client:client_id (*),
                    branch:branch_id (*),
                    items:sales_items!left(*)
                  `)
                  .eq('id', saleId)
                  .eq('tenant_id', tenantId)
                  .eq('platform_id', platformId)
                  .order('created_at', { foreignTable: 'sales_items', ascending: true })
                  .single();
                  
                const tenantPromise = coreSupabase
                  .from('tenants')
                  .select('name')
                  .eq('id', tenantId)
                  .eq('platform_id', platformId)
                  .single();

                const [
                  { data: saleData, error: saleError },
                  { data: tenantData, error: tenantError }
                ] = await Promise.all([salePromise, tenantPromise]);


                if (saleError) throw new Error(`Error fetching sale details: ${saleError.message}`);
                if (!saleData) throw new Error('Sale not found.');
                if (tenantError) throw new Error(`Error fetching tenant details: ${tenantError.message}`);

                // 2. Get Associated Payments
                const { data: payments, error: paymentsError } = await supabaseAdmin
                  .from('attention_payments')
                  .select('*')
                  .eq('attention_id', saleData.attention_id)
                  .eq('tenant_id', tenantId)
                  .eq('platform_id', platformId);

                if (paymentsError) throw new Error(`Error fetching payments: ${paymentsError.message}`);

                // 3. Combine and return
                responseData = { ...saleData, tenant: tenantData, payments: payments || [] };
                break;
              }      case 'get_attention_service_evidences': {
        const { attentionServiceId } = payload;
        if (!attentionServiceId) throw new Error('Attention Service ID is required.');

        const { data, error } = await supabaseAdmin
          .from('attention_service_evidences')
          .select('*')
          .eq('attention_service_id', attentionServiceId)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .order('created_at', { ascending: false });

        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get_payment_evidences': {
        const { attentionPaymentIds } = payload;
        if (!attentionPaymentIds || !Array.isArray(attentionPaymentIds) || attentionPaymentIds.length === 0) {
          throw new Error('attentionPaymentIds must be a non-empty array.');
        }

        const { data, error } = await supabaseAdmin
          .from('attention_payment_evidences')
          .select('id, file_name, google_drive_file_id')
          .in('attention_payment_id', attentionPaymentIds)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId);

        if (error) {
          throw new Error(`Error fetching payment evidence: ${error.message}`);
        }

        responseData = data || [];
        break;
      }

      case 'create_equipment_maintenance_record': {
        const { maintenanceData } = payload;
        const { data, error } = await supabaseAdmin.rpc('create_equipment_maintenance_record', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_maintenance_data: maintenanceData,
        });
        if (error) throw error;
        responseData = data;
        break;
      }

      // --- COMBO ACTIONS ---

      // --- PRODUCT IMAGE ACTIONS ---
      case 'get_product_images': {
        const { productId } = payload;
        if (!productId) throw new Error('Product ID is required.');
        responseData = await callRpc(supabaseAdmin, 'get_product_images', { p_tenant_id: tenantId, p_platform_id: platformId, p_product_id: productId });
        break;
      }

      case 'associate_product_image': {
        const { productId, google_drive_file_id } = payload;
        if (!productId || !google_drive_file_id) {
          throw new Error('productId and google_drive_file_id are required.');
        }
        responseData = await callRpc(supabaseAdmin, 'associate_product_image', { 
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_product_id: productId, 
          p_google_drive_file_id: google_drive_file_id 
        });
        break;
      }

      case 'delete_product_image': {
        const { imageId } = payload;
        if (!imageId) throw new Error('Image ID is required.');
        responseData = await callRpc(supabaseAdmin, 'delete_product_image', { p_tenant_id: tenantId, p_platform_id: platformId, p_image_id: imageId });
        break;
      }

      case 'set_primary_product_image': {
        const { productId, imageId } = payload;
        if (!productId || !imageId) throw new Error('Product ID and Image ID are required.');
        responseData = await callRpc(supabaseAdmin, 'set_primary_product_image', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_product_id: productId,
          p_image_id: imageId,
        });
        break;
      }

      // --- COMBO IMAGE ACTIONS ---
      case 'get_combo_images': {
        const { comboId } = payload;
        if (!comboId) throw new Error('Combo ID is required.');
        responseData = await callRpc(supabaseAdmin, 'get_combo_images', { p_tenant_id: tenantId, p_platform_id: platformId, p_combo_id: comboId });
        break;
      }

      case 'associate_combo_image': {
        const { comboId, google_drive_file_id } = payload;
        if (!comboId || !google_drive_file_id) {
          throw new Error('comboId and google_drive_file_id are required.');
        }
        responseData = await callRpc(supabaseAdmin, 'associate_combo_image', { 
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_combo_id: comboId, 
          p_google_drive_file_id: google_drive_file_id 
        });
        break;
      }

      case 'delete_combo_image': {
        const { imageId } = payload;
        if (!imageId) throw new Error('Image ID is required.');
        responseData = await callRpc(supabaseAdmin, 'delete_combo_image', { p_tenant_id: tenantId, p_platform_id: platformId, p_image_id: imageId });
        break;
      }

      case 'set_primary_combo_image': {
        const { comboId, imageId } = payload;
        if (!comboId || !imageId) throw new Error('Combo ID and Image ID are required.');
        responseData = await callRpc(supabaseAdmin, 'set_primary_combo_image', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_combo_id: comboId,
          p_image_id: imageId,
        });
        break;
      }

      // --- TREATMENT IMAGE ACTIONS ---
      case 'get_treatment_images': {
        const { treatmentId } = payload;
        if (!treatmentId) throw new Error('Treatment ID is required.');
        responseData = await callRpc(supabaseAdmin, 'get_treatment_images', { p_tenant_id: tenantId, p_platform_id: platformId, p_treatment_id: treatmentId });
        break;
      }

      case 'associate_treatment_image': {
        const { treatmentId, google_drive_file_id } = payload;
        if (!treatmentId || !google_drive_file_id) {
          throw new Error('treatmentId and google_drive_file_id are required.');
        }
        responseData = await callRpc(supabaseAdmin, 'associate_treatment_image', { 
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_treatment_id: treatmentId, 
          p_google_drive_file_id: google_drive_file_id 
        });
        break;
      }

      case 'delete_treatment_image': {
        const { imageId } = payload;
        if (!imageId) throw new Error('Image ID is required.');
        responseData = await callRpc(supabaseAdmin, 'delete_treatment_image', { p_tenant_id: tenantId, p_platform_id: platformId, p_image_id: imageId });
        break;
      }

      case 'set_primary_treatment_image': {
        const { treatmentId, imageId } = payload;
        if (!treatmentId || !imageId) throw new Error('Treatment ID and Image ID are required.');
        responseData = await callRpc(supabaseAdmin, 'set_primary_treatment_image', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_treatment_id: treatmentId,
          p_image_id: imageId,
        });
        break;
      }

      // --- PROJECT IMAGE ACTIONS ---
      case 'get_project_images': {
        const { projectId } = payload;
        if (!projectId) throw new Error('Project ID is required.');
        responseData = await callRpc(supabaseAdmin, 'get_project_images', { p_tenant_id: tenantId, p_platform_id: platformId, p_project_id: projectId });
        break;
      }

      case 'associate_project_image': {
        const { projectId, google_drive_file_id } = payload;
        if (!projectId || !google_drive_file_id) {
          throw new Error('projectId and google_drive_file_id are required.');
        }
        responseData = await callRpc(supabaseAdmin, 'associate_project_image', { 
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_project_id: projectId, 
          p_google_drive_file_id: google_drive_file_id 
        });
        break;
      }

      case 'delete_project_image': {
        const { imageId } = payload;
        if (!imageId) throw new Error('Image ID is required.');
        responseData = await callRpc(supabaseAdmin, 'delete_project_image', { p_tenant_id: tenantId, p_platform_id: platformId, p_image_id: imageId });
        break;
      }

      case 'set_primary_project_image': {
        const { projectId, imageId } = payload;
        if (!projectId || !imageId) throw new Error('Project ID and Image ID are required.');
        responseData = await callRpc(supabaseAdmin, 'set_primary_project_image', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_project_id: projectId,
          p_image_id: imageId,
        });
        break;
      }
      case 'get_service_images': {
        const { serviceId } = payload;
        if (!serviceId) throw new Error('Service ID is required.');
        const { data, error } = await supabaseAdmin.rpc('get_service_images', { p_tenant_id: tenantId, p_platform_id: platformId, p_service_id: serviceId });
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'update_product_images_order': {
        const { images_data } = payload;
        if (!images_data) {
          throw new Error('images_data is required for update_product_images_order.');
        }
        const { error } = await supabaseAdmin.rpc('update_product_images_order', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_images_data: images_data,
        });
        if (error) throw error;
        responseData = { success: true };
        break;
      }
      // --- END PRODUCT IMAGE ACTIONS ---

      case 'create_combo': {
        const { comboData, items } = payload;
        if (!comboData || !items || items.length === 0) {
          throw new Error('Combo data and at least one item are required.');
        }

        // 1. Create the master combo
        const { data: newCombo, error: comboError } = await supabaseAdmin
          .from('combos')
          .insert({ ...comboData, tenant_id: tenantId, platform_id: platformId })
          .select()
          .single();

        if (comboError) throw comboError;

        // 2. Prepare and insert the combo items
        const comboItems = items.map((item: any) => ({
          combo_id: newCombo.id,
          tenant_id: tenantId,
          platform_id: platformId,
          product_id: item.product_id || null,
          service_id: item.service_id || null,
          quantity: item.quantity,
          price: item.price,
          is_parallel: item.is_parallel || false,
          offset_minutes: item.offset_minutes || 0,
        }));

        const { error: itemsError } = await supabaseAdmin
          .from('combo_items')
          .insert(comboItems);

        if (itemsError) {
          // Rollback combo creation if item insertion fails
          await supabaseAdmin.from('combos').delete().eq('id', newCombo.id).eq('tenant_id', tenantId).eq('platform_id', platformId);
          throw itemsError;
        }

        responseData = newCombo;
        break;
      }

      case 'get_combos': {
        const { data, error } = await supabaseAdmin
          .from('combos')
          .select(`
            *,
            combo_items (
              *,
              product:products (name),
              service:services (name)
            ),
            combo_images:combo_images(*)
          `)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .order('name')
          .order('sort_order', { foreignTable: 'combo_images', ascending: true });

        if (error) throw error;
        responseData = data;
        break;
      }

      case 'update_combo': {
        const { comboId, comboData, items } = payload;
        if (!comboId || !comboData) { // Check for items removed
          throw new Error('Combo ID and data are required for update.');
        }

        // 1. Update the master combo details
        const { data: updatedCombo, error: comboError } = await supabaseAdmin
          .from('combos')
          .update(comboData)
          .eq('id', comboId)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .select()
          .single();

        if (comboError) throw comboError;

        // 2. If items are provided, update them.
        if (items && Array.isArray(items)) {
          // Delete all existing items for this combo
          const { error: deleteError } = await supabaseAdmin
            .from('combo_items')
            .delete()
            .eq('combo_id', comboId)
            .eq('tenant_id', tenantId)
            .eq('platform_id', platformId);
          
          if (deleteError) {
            throw new Error(`Failed to delete old combo items: ${deleteError.message}`);
          }

          // Prepare and insert the new combo items if the array is not empty
          if (items.length > 0) {
            const comboItems = items.map((item: any) => ({
              combo_id: comboId,
              tenant_id: tenantId,
              platform_id: platformId,
              product_id: item.product_id || null,
              service_id: item.service_id || null,
              quantity: item.quantity,
              price: item.price,
              is_parallel: item.is_parallel || false,
              offset_minutes: item.offset_minutes || 0,
            }));
    
            const { error: itemsError } = await supabaseAdmin
              .from('combo_items')
              .insert(comboItems);
    
            if (itemsError) {
              throw new Error(`Failed to insert new combo items: ${itemsError.message}`);
            }
          }
        }

        responseData = updatedCombo;
        break;
      }

      case 'delete_combo': {
        const { comboId } = payload;
        if (!comboId) throw new Error('Combo ID is required.');

        const { error } = await supabaseAdmin
          .from('combos')
          .delete()
          .eq('id', comboId)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId);

        if (error) throw error;
        responseData = { success: true };
        break;
      }

      case 'assign_combo_to_branch': {
        const { combo_id, branch_id, is_active } = payload;
        if (!combo_id || !branch_id) throw new Error('Combo ID and Branch ID are required.');

        const { data, error } = await supabaseAdmin
          .from('branch_combos')
          .upsert({
            combo_id,
            branch_id,
            tenant_id: tenantId,
            platform_id: platformId,
            is_active: is_active ?? true,
          }, { onConflict: 'branch_id, combo_id, platform_id' })
          .select()
          .single();

        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get_combo_branch_details': {
        const { comboId, branchId } = payload;
        if (!comboId || !branchId) throw new Error('Combo ID and Branch ID are required.');

        const { data, error } = await supabaseAdmin.rpc('get_combo_branch_details', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_branch_id: branchId,
          p_combo_id: comboId,
        });

        if (error) throw error;
        responseData = data;
        break;
      }



      case 'unassign_combo_from_branch': {
        const { combo_id, branch_id } = payload;
        if (!combo_id || !branch_id) throw new Error('Combo ID and Branch ID are required.');

        const { error } = await supabaseAdmin
          .from('branch_combos')
          .delete()
          .eq('combo_id', combo_id)
          .eq('branch_id', branch_id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId);

        if (error) throw error;
        responseData = { success: true };
        break;
      }

      case 'get_assigned_branches_for_combo': {
        const { comboId } = payload;
        if (!comboId) throw new Error('Combo ID is required.');

        const { data, error } = await supabaseAdmin
          .from('branch_combos')
          .select('branch_id, is_active, is_visible_on_microsite, branches(name)')
          .eq('combo_id', comboId)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId);

        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get_combos_for_branch': {
        const { branchId, searchTerm } = payload;
        if (!branchId) throw new Error('Branch ID is required.');

        const { data: branchCombosData, error: bcError } = await supabaseAdmin
          .from('branch_combos')
          .select(`
            is_active,
            combo_id,
            is_visible_on_microsite
          `)
          .eq('branch_id', branchId)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId);

        if (bcError) throw bcError;

        const detailedCombosPromises = branchCombosData.map(async (bc: any) => {
            const { data: comboDetails, error: detailsError } = await supabaseAdmin.rpc('get_combo_branch_details', {
                p_tenant_id: tenantId,
                p_platform_id: platformId,
                p_branch_id: branchId,
                p_combo_id: bc.combo_id,
            });
            if (detailsError) {
                console.error(`Error fetching details for combo ${bc.combo_id}:`, detailsError);
                return null;
            }
            return {
                ...comboDetails,
                is_active_in_branch: bc.is_active,
                is_visible_on_microsite: bc.is_visible_on_microsite
            };
        });

        let detailedCombos = (await Promise.all(detailedCombosPromises)).filter(Boolean);

        if (searchTerm) {
          detailedCombos = detailedCombos.filter(c => c.name.toLowerCase().includes(searchTerm.toLowerCase()));
        }

        responseData = detailedCombos;
        break;
      }

      case 'update_branch_combo_status': {
        const { combo_id, branch_id, updates } = payload;
        if (!combo_id || !branch_id || !updates) {
          throw new Error('Combo ID, Branch ID, and updates are required.');
        }

        const { data, error } = await supabaseAdmin
          .from('branch_combos')
          .update(updates)
          .eq('combo_id', combo_id)
          .eq('branch_id', branch_id)
          .eq('tenant_id', tenantId)
          .select()
          .single();

        if (error) throw error;
        responseData = data;
        break;
      }

      // --- USER SERVICE COMMISSIONS ---
      case 'get_user_service_commissions': {
        const { userId } = payload;
        if (!userId) throw new Error('User ID is required.');
        const { data, error } = await supabaseAdmin
          .from('service_user_commissions')
          .select('*, services(id, name)')
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .eq('user_id', userId);
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'create_service_commission': {
        const { commissionData } = payload;
        if (!commissionData) throw new Error('Commission data is required.');
        const { data, error } = await supabaseAdmin
          .from('service_user_commissions')
          .insert({ ...commissionData, tenant_id: tenantId, platform_id: platformId })
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'update_service_commission': {
        const { id, updates } = payload;
        if (!id || !updates) throw new Error('Commission ID and updates are required.');
        const { data, error } = await supabaseAdmin
          .from('service_user_commissions')
          .update(updates)
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'delete_service_commission': {
        const { id } = payload;
        if (!id) throw new Error('Commission ID is required.');
        const { error } = await supabaseAdmin
          .from('service_user_commissions')
          .delete()
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId);
        if (error) throw error;
        responseData = { success: true };
        break;
      }

      case 'get_attentions': {
        const { branchId, userId, statusFilter, dateRange } = payload;
        const { data, error } = await supabaseAdmin.rpc('get_attentions_with_details', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_branch_id: branchId === 'all' ? null : branchId,
          p_user_id: userId === 'all' ? null : userId,
          p_status_filter: statusFilter === 'all' ? null : statusFilter,
          p_start_date: dateRange?.from,
          p_end_date: dateRange?.to
        });

        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get_attention_datetimes': {
        const { p_branch_id, p_user_id } = payload;
        const { data, error } = await supabaseAdmin.rpc('get_attention_datetimes', {
            p_tenant_id: tenantId,
            p_platform_id: platformId,
            p_branch_id: p_branch_id === 'all' ? null : p_branch_id,
            p_user_id: p_user_id === 'all' ? null : p_user_id
        });

        if (error) throw error;
        responseData = data;
        break;
      }

      case 'create_full_attention': {
        // Explicitly destructure all parameters from the payload
        const {
            p_client_id,
            p_attention_datetime,
            p_notes,
            p_services,
            p_products,
            p_combos,
            p_payments, // The new parameter
            p_tenant_id,
            p_branch_id,
            p_total_amount,
        } = payload;

        // Create a new object to ensure all parameters are present for the RPC call
        const rpcPayload = {
            p_client_id,
            p_attention_datetime,
            p_notes,
            p_services,
            p_products,
            p_combos,
            p_payments: p_payments || [], // Ensure it's at least an empty array
            p_tenant_id: p_tenant_id || tenantId,
            p_platform_id: platformId,
            p_branch_id,
            p_total_amount,
        };

        const { data, error } = await supabaseAdmin.rpc('create_full_attention', rpcPayload);
        if (error) throw error;

        // --- Inicio: Lógica de Notificación ---
        try {
          // Notificar al usuario asignado si la cita se creó correctamente
          if (data && data.id && payload.services && payload.services.length > 0) {
            const staffUserId = payload.services[0].user_id;
            const clientId = payload.client_id || p_client_id;
            const attentionId = data.id;
            const attentionDt = new Date(payload.attention_datetime || p_attention_datetime);

            if (staffUserId && clientId) {
              // Obtener el nombre del cliente para el mensaje
              const { data: client, error: clientError } = await supabaseAdmin
                .from('clients')
                .select('name')
                .eq('id', clientId)
                .eq('tenant_id', tenantId)
                .eq('platform_id', platformId)
                .single();

              if (clientError) {
                console.error(`Notification Error: Could not fetch client name for id ${clientId}:`, clientError.message);
              } else {
                const clientName = client.name || 'un cliente';
                const formattedDate = attentionDt.toLocaleDateString('es-ES', { day: '2-digit', month: 'long' });
                const formattedTime = attentionDt.toLocaleTimeString('es-ES', { hour: '2-digit', minute: '2-digit' });

                await createUserNotification(
                  supabaseAdmin,
                  tenantId, // tenantId del token
                  staffUserId,
                  'new_appointment', // tipo de notificación
                  'Nueva Cita Asignada', // título
                  `Se te asignó una cita con ${clientName} el ${formattedDate} a las ${formattedTime}.`, // cuerpo
                  `/attentions/${attentionId}` // enlace
                );
              }
            }
          }
        } catch (notificationError) {
          // No bloquear la respuesta principal si la notificación falla
          console.error('Failed to send appointment notification:', notificationError);
        }
        // --- Fin: Lógica de Notificación ---

        responseData = data;
        break;
      }

      case 'cancel_attention': {
        const { attentionId } = payload;
        if (!attentionId) {
          throw new Error('Attention ID is required for cancellation.');
        }
        // This RPC handles the status update and the notification
        const { error } = await supabaseAdmin.rpc('cancel_attention_and_notify', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_attention_id: attentionId,
        });
        if (error) throw error;
        responseData = { success: true };
        break;
      }

      case 'reschedule_attention': {
        const { p_attention_id, p_new_datetime, p_reason, p_fault } = payload;
        if (!p_attention_id || !p_new_datetime || !p_reason || !p_fault) {
          throw new Error('Attention ID, new datetime, reason, and fault are required.');
        }

        // 1. Get the current attention details
        const { data: currentAttention, error: fetchError } = await supabaseAdmin
          .from('attentions')
          .select('attention_datetime, client_id')
          .eq('id', p_attention_id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .single();

        if (fetchError) throw fetchError;

        // 2. Update the attention datetime
        const { error: updateError } = await supabaseAdmin
          .from('attentions')
          .update({ attention_datetime: p_new_datetime })
          .eq('id', p_attention_id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId);

        if (updateError) throw updateError;

        // 3. Log the reschedule event
        const { error: logError } = await supabaseAdmin
          .from('rescheduled_attentions')
          .insert({
            tenant_id: tenantId,
            platform_id: platformId,
            attention_id: p_attention_id,
            client_id: currentAttention.client_id,
            original_date: currentAttention.attention_datetime,
            new_date: p_new_datetime,
            reason: p_reason,
            user_id: userId,
            fault: p_fault,
          });

        if (logError) {
          // If logging fails, we should ideally roll back the attention update.
          // For now, we'll just log the error and continue.
          console.error('Failed to log reschedule event:', logError);
        }

        responseData = { success: true };
        break;
      }

      case 'process_attention_payment': {
        const { attention, paymentOptions } = payload;
        if (!attention || !paymentOptions) {
          throw new Error('Attention and paymentOptions are required.');
        }

        // Validar montos
        const totalPaid = paymentOptions.payment_methods.reduce((sum, p) => sum + p.amount, 0);
        const discountAmount = paymentOptions.discount || 0;
        const totalWithDiscount = attention.total_amount - discountAmount;

        if (totalPaid < totalWithDiscount) {
          throw new Error(`El monto pagado (${totalPaid}) es menor al total con descuento (${totalWithDiscount}).`);
        }

        const wompiPaymentMethod = paymentOptions.payment_methods.find(p => p.method.toLowerCase() === 'wompi');
        let useWompi = false;

        if (wompiPaymentMethod) {
          // Si se incluye 'wompi', verificar si el tenant tiene la integración activa
          const { data: wompiIntegration, error: integrationError } = await supabaseAdmin
            .from('tenant_integrations')
            .select('id')
            .eq('tenant_id', tenantId)
            .eq('platform_id', platformId)
            .eq('provider', 'wompi-co')
            .eq('is_active', true)
            .single();
          
          if (integrationError && integrationError.code !== 'PGRST116') { // PGRST116 = no rows
            throw new Error(`Error al verificar la integración de Wompi: ${integrationError.message}`);
          }

          if (wompiIntegration) {
            useWompi = true;
          }
        }

        // Insertar los registros de pago
        const createdPayments = [];
        for (const payment of paymentOptions.payment_methods) {
          const { data, error } = await supabaseAdmin.from('attention_payments').insert({
            attention_id: attention.id,
            payment_method_id: payment.method_id,
            amount: payment.amount,
            status: (payment.method.toLowerCase() === 'wompi' && useWompi) ? 'pending' : 'completed',
            tenant_id: tenantId,
            platform_id: platformId,
          }).select().single(); // Use single() to get a single object

          if (error) {
            throw new Error(`Error al registrar el pago: ${error.message}`);
          }
          if (data) {
            createdPayments.push(data);
          }
        }

        let saleId = null;
        const hasPendingPayments = createdPayments.some(p => p.status === 'pending');

                  // Si no hay pagos pendientes, la transacción se considera completa en nuestro sistema.
                  // Ejecutamos la lógica de negocio de inmediato.
                  if (!hasPendingPayments) {
                    const { error: updateError } = await supabaseAdmin
                      .from('attentions')
                      .update({ status: 'Pagada' })
                      .eq('id', attention.id)
                      .eq('tenant_id', tenantId)
                      .eq('platform_id', platformId);
        
                    if (updateError) {
                      throw new Error(`Error al actualizar el estado de la atención: ${updateError.message}`);
                    }
        
                    // The function now returns a JSONB object with saleId and commissions
                    try {
                      const { data: saleProcessingResult, error } = await supabaseAdmin.rpc('process_sale_from_attention', { 
                        p_tenant_id: tenantId,
                        p_platform_id: platformId,
                        p_attention_id: attention.id 
                      });
        
                      if (error) throw error;
        
                      saleId = saleProcessingResult.saleId;
                      
                      // --- START: Generate Satisfaction Survey ---
                      try {
                        // Fetch full attention details to ensure we have client_id and branch_id
                        const { data: fullAttention, error: fetchAttentionError } = await supabaseAdmin
                          .from('attentions')
                          .select('id, client_id, branch_id')
                          .eq('id', attention.id)
                          .eq('tenant_id', tenantId)
                          .eq('platform_id', platformId)
                          .single();
        
                        if (fetchAttentionError) {
                          console.error(`Error fetching full attention details for survey generation for attention ${attention.id}:`, fetchAttentionError.message);
                          // Don't throw, as survey generation is a secondary process
                        } else if (fullAttention) {
                          const { data: newSurvey, error: surveyError } = await supabaseAdmin
                            .from('satisfaction_surveys')
                            .insert({
                              attention_id: fullAttention.id,
                              client_id: fullAttention.client_id,
                              tenant_id: tenantId,
                              platform_id: platformId,
                              branch_id: fullAttention.branch_id,
                              status: 'generated'
                            })
                            .select('survey_token')
                            .single();
        
                          if (surveyError) {
                            console.error(`Error creating satisfaction survey for attention ${attention.id}:`, surveyError.message);
                          } else if (newSurvey) {
                            // Fetch client's email for notification
                            const { data: clientData, error: clientFetchError } = await supabaseAdmin
                              .from('clients')
                              .select('name, email')
                              .eq('id', fullAttention.client_id)
                              .eq('tenant_id', tenantId)
                              .eq('platform_id', platformId)
                              .single();
        
                            if (clientFetchError) {
                              console.error(`Error fetching client data for survey notification for client ${fullAttention.client_id}:`, clientFetchError.message);
                            } else if (clientData && clientData.email) {
                              const surveyUrl = `${Deno.env.get('PUBLIC_APP_BASE_URL')}/survey/${newSurvey.survey_token}`;
                              await queueClientNotification(
                                supabaseAdmin,
                                tenantId,
                                platformId,
                                fullAttention.client_id,
                                'satisfaction_survey', // New template type
                                {
                                  client_name: clientData.name,
                                  survey_link: surveyUrl,
                                  attention_id: fullAttention.id,
                                  // Add more dynamic data for the template as needed
                                }
                              );
                              console.log(`Satisfaction survey created and notification queued for attention ${attention.id}. Survey URL: ${surveyUrl}`);
                            } else {
                              console.warn(`No email found for client ${fullAttention.client_id} for satisfaction survey notification.`);
                            }
                          }
                        }
                      } catch (surveyGenerationError) {
                        console.error(`Exception during satisfaction survey generation for attention ${attention.id}:`, surveyGenerationError);
                      }
                      // --- END: Generate Satisfaction Survey ---
        
                      // --- Inicio: Integración Facturación Electrónica ---                        let invoiceId = null;
                        try {
                            // 1. Generar la factura interna si no existe (o obtener su ID si ya existe)
                            const { data: generatedInvoiceId, error: invoiceGenError } = await supabaseAdmin.rpc('generate_invoice_for_attention', {
                                p_tenant_id: tenantId,
                                p_platform_id: platformId,
                                p_attention_id: attention.id
                            });
            
                            if (invoiceGenError) {
                                console.error(`Error al generar la factura para la atención ${attention.id}:`, invoiceGenError);
                                // No lanzar excepción para no bloquear el flujo de pago, pero registrar el error.
                                // La factura no se enviará electrónicamente.
                            } else {
                                invoiceId = generatedInvoiceId;
                                console.log(`Factura interna generada/obtenida con ID: ${invoiceId}`);
            
                                // 2. Enviar la factura al proveedor de facturación electrónica (Dataico)
                                const { data: eInvoiceResponse, error: eInvoiceError } = await supabaseAdmin.rpc('send_electronic_document', {
                                    p_tenant_id: tenantId,
                                    p_platform_id: platformId,
                                    p_document_id: invoiceId,
                                    p_provider_slug: 'dataico_fe_co', // Hardcoded for now as per user's request
                                    p_document_type: 'invoice' // Hardcoded for now
                                });
            
                                if (eInvoiceError) {
                                    console.error(`Error al enviar factura electrónica ${invoiceId} a Dataico:`, eInvoiceError);
                                    // Actualizar la factura con el mensaje de error de e-invoicing
                                    await supabaseAdmin.from('invoices')
                                        .update({ error_message: eInvoiceError.message })
                                        .eq('id', invoiceId)
                                        .eq('tenant_id', tenantId)
                                        .eq('platform_id', platformId);
                                } else {
                                    console.log(`Factura electrónica ${invoiceId} enviada a Dataico. Respuesta:`, eInvoiceResponse);
                                    // Aquí podrías actualizar la factura con el provider_reference_id si la respuesta lo contiene
                                    if (eInvoiceResponse && eInvoiceResponse.dataico_response && eInvoiceResponse.dataico_response.id) {
                                        await supabaseAdmin.from('invoices')
                                            .update({ provider_reference_id: eInvoiceResponse.dataico_response.id })
                                            .eq('id', invoiceId)
                                            .eq('tenant_id', tenantId)
                                            .eq('platform_id', platformId);
                                    }
                                }
                            }
                        } catch (eInvoicingProcessError) {
                            console.error(`Excepción durante el proceso de facturación electrónica para atención ${attention.id}:`, eInvoicingProcessError);
                            if (invoiceId) {
                                await supabaseAdmin.from('invoices')
                                    .update({ error_message: `Excepción en e-invoicing: ${eInvoicingProcessError.message}` })
                                    .eq('id', invoiceId)
                                    .eq('tenant_id', tenantId)
                                    .eq('platform_id', platformId);
                            }
                        }
                        // --- Fin: Integración Facturación Electrónica ---
            
                        // --- Inicio: Notificación de Comisiones ---
                        if (saleProcessingResult.commissions && saleProcessingResult.commissions.length > 0) {
                          for (const commission of saleProcessingResult.commissions) {
                            // Formatear el monto a un formato de moneda local (ej. peso colombiano)
                            const formattedAmount = new Intl.NumberFormat('es-CO', {
                              style: 'currency',
                              currency: 'COP',
                              minimumFractionDigits: 0,
                              maximumFractionDigits: 0
                            }).format(commission.amount);
            
                            await createUserNotification(
                              supabaseAdmin,
                              tenantId,
                              commission.user_id,
                              'commission_earned',
                              '¡Comisión Ganada!',
                              `Ganaste una comisión de ${formattedAmount} por la venta de ${commission.item_name}.`,
                              `/app/commissions` // Corrected link to the commissions page
                            );
                          }
                        }
                        // --- Fin: Notificación de Comisiones ---
          } catch (saleError) {
            if (saleError.message.includes('No active document sequence found')) {
              throw new Error('No se ha configurado una secuencia de numeración para las ventas. Por favor, contacte al administrador.');
            }
            throw saleError; // Re-throw other errors
          }
        }

        // Ahora, manejamos la redirección a la pasarela de pago si es necesario.
        if (useWompi && wompiPaymentMethod) {
          const { data: wompiData, error: wompiError } = await supabaseAdmin.functions.invoke('wompi-generate-checkout', {
            body: {
              tenantId,
              redirectUrl: `${Deno.env.get('SUPABASE_URL').replace('/supabase', '')}/payment-success?attention_id=${attention.id}`,
              userId,
              amountInCents: wompiPaymentMethod.amount * 100,
              currency: 'COP',
              actions_on_success: createdPayments.map(p => ({ action: 'update_attention_payment_status', payload: { payment_id: p.id, new_status: 'completed' } })),
            },
          });

          if (wompiError) {
            throw new Error(`Error al generar el checkout de Wompi: ${wompiError.message}`);
          }

          if (wompiData.success) {
            responseData = { wompiCheckout: true, checkoutData: wompiData.checkoutData, createdPayments, saleId };
          } else {
            throw new Error(wompiData.error || 'Error desconocido al iniciar el pago con Wompi.');
          }
        } else {
          // Si no se usó Wompi (o ninguna otra pasarela que requiera redirección),
          // simplemente devolvemos la respuesta estándar.
          responseData = { wompiCheckout: false, createdPayments, saleId };
        }
        break;
      }

      case 'get_invoice_details_for_attention': {
        const { attention_id } = payload;
        if (!attention_id) {
          throw new Error('Attention ID is required.');
        }

        // 1. Asegurarse de que la factura exista, si no, la crea.
        const { data: invoiceId, error: rpcError } = await supabaseAdmin.rpc('generate_invoice_for_attention', { 
          p_attention_id: attention_id 
        });

        if (rpcError) {
          throw new Error(`Error ensuring invoice exists: ${rpcError.message}`);
        }

        // 2. Obtener los detalles completos de la factura.
        const { data: invoiceDetails, error: queryError } = await supabaseAdmin
          .from('invoices')
          .select(`
            *,
            client:billed_to_client_id (*),
            branch:attentions!inner(branch_id(name, address)),
            items:invoice_items(*)
          `)
          .eq('id', invoiceId)
          .single();

        if (queryError) {
          throw new Error(`Error fetching invoice details: ${queryError.message}`);
        }
        
        // 3. (Platzhalter für die Zukunft) Überprüfen Sie die E-Invoicing-Konfiguration
        const { data: tenantSettings } = await supabaseAdmin
            .from('tenant_settings')
            .select('settings_data')
            .eq('tenant_id', tenantId)
            .single();

        const eInvoicingConfig = tenantSettings?.settings_data?.electronic_invoicing || { enabled: false, mode: 'manual' };


        responseData = { ...invoiceDetails, eInvoicingConfig };
        break;
      }

      case 'add_attention_service': {
        const { newService } = payload;
        const { data, error } = await supabaseAdmin
          .from('attention_services')
          .insert(newService)
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get_available_users': {
        const { serviceId, itemType, appointmentDate, appointmentTime, duration, branchId, assignedUserId, clientId } = payload; // Added clientId

        if (!serviceId || !itemType || !appointmentDate || !appointmentTime || !duration || !branchId || !tenantId || !clientId) { // Added clientId validation
          throw new Error('Missing required fields for get_available_users.');
        }

        const rpcParams = {
          p_item_id: serviceId,
          p_item_type: itemType,
          p_branch_id: branchId,
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_appointment_date: appointmentDate,
          p_appointment_time: appointmentTime,
          p_duration_minutes: duration,
          p_assigned_user_id: assignedUserId || null,
          p_client_id: clientId, // Added p_client_id
        };

        const { data, error } = await supabaseAdmin.rpc('check_user_availability', rpcParams);
        if (error) {
          console.error('Error calling check_user_availability RPC:', error);
          throw new Error(error.message);
        }
        
        responseData = data;
        break;
      }

      // --- USER PRODUCT COMMISSIONS ---
      case 'get_user_product_commissions': {
        const { userId, branchId } = payload;
        if (!userId || !branchId) throw new Error('User ID and Branch ID are required.');
        const { data, error } = await supabaseAdmin
          .from('product_user_commissions')
          .select('*, products(id, name)')
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .eq('user_id', userId)
          .eq('branch_id', branchId);
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'create_product_commission': {
        const { commissionData } = payload;
        if (!commissionData) throw new Error('Commission data is required.');
        const { data, error } = await supabaseAdmin
          .from('product_user_commissions')
          .insert({ ...commissionData, tenant_id: tenantId, platform_id: platformId })
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'update_product_commission': {
        const { id, updates } = payload;
        if (!id || !updates) throw new Error('Commission ID and updates are required.');
        const { data, error } = await supabaseAdmin
          .from('product_user_commissions')
          .update(updates)
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'delete_product_commission': {
        const { id } = payload;
        if (!id) throw new Error('Commission ID is required.');
        const { error } = await supabaseAdmin
          .from('product_user_commissions')
          .delete()
          .eq('id', id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId);
      if (error) throw error;
        responseData = { success: true };
        break;
      }

      // --- COMMISSIONS & PAYSLIPS ACTIONS ---
      case 'get_earned_commissions': {
        const { filters } = payload; // filters: { dateRange, status, userId, branchId }
        const userRole = decodedToken.app_metadata?.assignments?.[0]?.role_name;

        let query = supabaseAdmin
          .from('earned_commissions')
          .select(`*, branch:branch_id ( name )`) // Select branch name directly
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId);

        // Apply filters
        if (filters?.status) {
          query = query.eq('status', filters.status);
        }
        if (filters?.dateRange?.from) {
          query = query.gte('created_at', filters.dateRange.from);
        }
        if (filters?.dateRange?.to) {
          query = query.lte('created_at', filters.dateRange.to);
        }

        // Apply RBAC
        if (userRole === 'tenant_user') {
          query = query.eq('user_id', userId);
        } else if (userRole === 'tenant_admin') {
          const adminBranchId = decodedToken.app_metadata?.assignments?.[0]?.branch_id;
          query = query.eq('branch_id', adminBranchId);
          if (filters?.userId) {
            query = query.eq('user_id', filters.userId);
          }
        } else if (userRole === 'tenant_super_admin') {
          if (filters?.branchId) {
            query = query.eq('branch_id', filters.branchId);
          }
          if (filters?.userId) {
            query = query.eq('user_id', filters.userId);
          }
        }

        const { data: commissions, error } = await query.order('created_at', { ascending: false });

        if (error) throw error;
        
        if (!commissions || commissions.length === 0) {
            responseData = [];
            break;
        }

        // Manual join with user data
        const userIds = [...new Set(commissions.map(c => c.user_id))];
        const { data: { users }, error: usersError } = await supabaseAdmin.auth.admin.listUsers({
            page: 1,
            perPage: 1000,
        });

        if (usersError) throw usersError;

        const usersMap = new Map(users.map(u => {
            const firstName = u.user_metadata?.first_name || '';
            const lastName = u.user_metadata?.last_name || '';
            const fullName = `${firstName} ${lastName}`.trim();
            return [u.id, { full_name: fullName || u.email }];
        }));

        const enrichedCommissions = commissions.map(c => ({
            ...c,
            user: usersMap.get(c.user_id) || { full_name: 'Usuario Desconocido' }
        }));

        responseData = enrichedCommissions;
        break;
      }


      case 'get_payslips': {
        const { filters } = payload; // filters: { dateRange, userId, branchId }
        const userRole = decodedToken.app_metadata?.assignments?.[0]?.role_name;

        let query = supabaseAdmin
          .from('payslips')
          .select(`*, branch:branch_id ( name )`) // Select branch name directly
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId);

        // Apply filters
        if (filters?.dateRange?.from) {
          query = query.gte('payslip_date', filters.dateRange.from);
        }
        if (filters?.dateRange?.to) {
          query = query.lte('payslip_date', filters.dateRange.to);
        }

        // Apply RBAC
        if (userRole === 'tenant_user') {
          query = query.eq('user_id', userId);
        } else if (userRole === 'tenant_admin') {
          const adminBranchId = decodedToken.app_metadata?.assignments?.[0]?.branch_id;
          query = query.eq('branch_id', adminBranchId);
          if (filters?.userId) {
            query = query.eq('user_id', filters.userId);
          }
        } else if (userRole === 'tenant_super_admin') {
          if (filters?.branchId) {
            query = query.eq('branch_id', filters.branchId);
          }
          if (filters?.userId) {
            query = query.eq('user_id', filters.userId);
          }
        }

        const { data: payslips, error } = await query.order('payslip_date', { ascending: false });

        if (error) throw error;

        if (!payslips || payslips.length === 0) {
            responseData = [];
            break;
        }

        // Manual join with user data
        const userIds = [...new Set(payslips.map(p => p.user_id))];
        const { data: { users }, error: usersError } = await supabaseAdmin.auth.admin.listUsers({
            page: 1,
            perPage: 1000,
        });

        if (usersError) throw usersError;

        const usersMap = new Map(users.map(u => {
            const firstName = u.user_metadata?.first_name || '';
            const lastName = u.user_metadata?.last_name || '';
            const fullName = `${firstName} ${lastName}`.trim();
            return [u.id, { full_name: fullName || u.email }];
        }));

        const enrichedPayslips = payslips.map(p => ({
            ...p,
            user: usersMap.get(p.user_id) || { full_name: 'Usuario Desconocido' }
        }));

        responseData = enrichedPayslips;
        break;
      }

      case 'create_payslip': {
        const {
          payslip_user_id,
          branch_id,
          total_amount,
          payment_method,
          notes,
          commission_ids,
        } = payload;

        if (!payslip_user_id || !branch_id || !total_amount || !commission_ids || commission_ids.length === 0) {
          throw new Error('User ID, branch ID, total amount, and at least one commission ID are required.');
        }

        // 1. Create the payslip with 'pending_signature' status
        const { data: newPayslip, error: payslipError } = await supabaseAdmin
          .from('payslips')
          .insert({
            tenant_id: tenantId,
            platform_id: platformId,
            branch_id: branch_id,
            user_id: payslip_user_id,
            total_amount: total_amount,
            payment_method: payment_method,
            notes: notes,
            status: 'pending_signature', // New status
          })
          .select()
          .single();

        if (payslipError) {
          throw new Error(`Could not create payslip: ${payslipError.message}`);
        }

        // 2. Create the junction table entries
        const payslipCommissions = commission_ids.map((commission_id: string) => ({
          payslip_id: newPayslip.id,
          commission_id: commission_id,
          tenant_id: tenantId,
          platform_id: platformId,
        }));

        const { error: junctionError } = await supabaseAdmin
          .from('payslip_commissions')
          .insert(payslipCommissions);

        if (junctionError) {
          // Rollback payslip creation
          await supabaseAdmin.from('payslips').delete().eq('id', newPayslip.id).eq('tenant_id', tenantId).eq('platform_id', platformId);
          throw new Error(`Could not link commissions to payslip: ${junctionError.message}`);
        }

        // 3. Update the status of the commissions to 'processing'
        const { error: updateError } = await supabaseAdmin
          .from('earned_commissions')
          .update({ status: 'processing' })
          .in('id', commission_ids)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId);

        if (updateError) {
          // This is more complex to roll back. For now, we log the error.
          console.error(`Failed to update commission statuses to 'processing': ${updateError.message}`);
          throw new Error(`Failed to update commission statuses: ${updateError.message}`);
        }
        
        // 4. Notify the user to sign the payslip
        const formattedAmount = new Intl.NumberFormat('es-CO', {
          style: 'currency',
          currency: 'COP',
          minimumFractionDigits: 0,
          maximumFractionDigits: 0
        }).format(total_amount);

        await createUserNotification(
          supabaseAdmin,
          tenantId,
          payslip_user_id,
          'payslip_pending_signature',
          'Liquidación de comisiones lista para firmar',
          `Tienes una liquidación por ${formattedAmount} lista para tu revisión y firma.`,
          `/staff/commissions` // Link to the commissions/payslips page
        );

        responseData = { success: true, payslip: newPayslip };
        break;
      }

      case 'sign_payslip': {
        const { payslip_id, google_drive_file_id, file_name, mime_type, file_size } = payload;
        if (!payslip_id || !google_drive_file_id || !file_name || !mime_type || !file_size) {
          throw new Error('Payslip ID, Google Drive File ID, file name, mime type, and file size are required.');
        }

        // 1. Update the payslip status
        const { data: updatedPayslip, error: payslipError } = await supabaseAdmin
          .from('payslips')
          .update({ status: 'paid' })
          .eq('id', payslip_id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .select('id, user_id, total_amount, branch_id')
          .single();

        if (payslipError) {
          throw new Error(`Could not update payslip: ${payslipError.message}`);
        }

        // 2. Insert the signature evidence into commission_payment_evidences
        const { error: evidenceError } = await supabaseAdmin
          .from('commission_payment_evidences')
          .insert({
            payslip_id: payslip_id,
            google_drive_file_id: google_drive_file_id,
            file_name: file_name,
            mime_type: mime_type,
            file_size: file_size,
            tenant_id: tenantId,
            platform_id: platformId,
            branch_id: updatedPayslip.branch_id, // Get branch_id from updatedPayslip
            user_id: updatedPayslip.user_id, // Get user_id from updatedPayslip
          });

        if (evidenceError) {
          // Log and potentially revert payslip status if evidence insertion fails
          console.error(`Failed to insert commission payment evidence: ${evidenceError.message}`);
          // Optionally, revert payslip status here if atomicity is critical
          throw new Error('Payslip signed, but failed to record evidence.');
        }

        // 2. Get all commission IDs associated with the payslip
        const { data: commissionLinks, error: linksError } = await supabaseAdmin
          .from('payslip_commissions')
          .select('commission_id')
          .eq('payslip_id', payslip_id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId);

        if (linksError) {
          throw new Error(`Could not retrieve commissions for payslip: ${linksError.message}`);
        }

        const commissionIdsToUpdate = commissionLinks.map(link => link.commission_id);

        // 3. Update the status of all linked commissions to 'paid'
        if (commissionIdsToUpdate.length > 0) {
          const { error: updateCommissionsError } = await supabaseAdmin
            .from('earned_commissions')
            .update({ status: 'paid' })
            .in('id', commissionIdsToUpdate)
            .eq('tenant_id', tenantId)
            .eq('platform_id', platformId);

          if (updateCommissionsError) {
            // At this point, rollback is very difficult. Log and alert.
            console.error(`CRITICAL: Failed to update status for commissions ${commissionIdsToUpdate.join(', ')} after payslip ${payslip_id} was signed.`);
            throw new Error('Payslip signed, but failed to update commission statuses.');
          }
        }
        
        // 4. (Optional) Notify admin or user that it's completed
        const formattedAmount = new Intl.NumberFormat('es-CO', {
          style: 'currency',
          currency: 'COP',
          minimumFractionDigits: 0,
          maximumFractionDigits: 0
        }).format(updatedPayslip.total_amount);

        await createUserNotification(
          supabaseAdmin,
          tenantId,
          updatedPayslip.user_id,
          'payslip_paid',
          'Comprobante de pago firmado',
          `Tu pago de comisiones por ${formattedAmount} ha sido completado y firmado.`,
          `/staff/commissions`
        );

        responseData = { success: true, payslip: updatedPayslip };
        break;
      }

      case 'get_payslip_evidence': {
        const { payslip_id } = payload;
        if (!payslip_id) throw new Error('Payslip ID is required.');

        const { data, error } = await supabaseAdmin
          .from('commission_payment_evidences')
          .select('google_drive_file_id')
          .eq('payslip_id', payslip_id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .single();

        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get_payslip_commission_details': {
        const { payslip_id } = payload;
        if (!payslip_id) throw new Error('Payslip ID is required.');

        const { data: payslipDetails, error: rpcError } = await supabaseAdmin.rpc('get_payslip_details', { p_tenant_id: tenantId, p_platform_id: platformId, p_payslip_id: payslip_id });

        if (rpcError) throw rpcError;

        const professionalId = payslipDetails.payslip.user_id;
        const { data: { user: professional }, error: userError } = await supabaseAdmin.auth.admin.getUserById(professionalId);

        if (userError) throw userError;

        const professionalInfo = {
          first_name: professional.user_metadata?.first_name || '',
          last_name: professional.user_metadata?.last_name || '',
          email: professional.user_metadata?.real_email || professional.email,
        };

        responseData = {
          ...payslipDetails,
          professional: professionalInfo,
        };
        break;
      }

      case 'void_commission': {
        const { commission_id, reason } = payload;
        if (!commission_id || !reason) {
          throw new Error('Commission ID and reason are required to void a commission.');
        }

        // 1. Fetch the commission to get the user_id for notification
        const { data: commission, error: fetchError } = await supabaseAdmin
          .from('earned_commissions')
          .select('user_id, commission_amount')
          .eq('id', commission_id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .single();

        if (fetchError) {
          throw new Error(`Could not find commission to void: ${fetchError.message}`);
        }

        // 2. Update the commission status and reason
        const { data: updatedCommission, error: updateError } = await supabaseAdmin
          .from('earned_commissions')
          .update({ status: 'voided', void_reason: reason })
          .eq('id', commission_id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .select()
          .single();

        if (updateError) {
          throw new Error(`Could not void commission: ${updateError.message}`);
        }

        // 3. Notify the user
        const formattedAmount = new Intl.NumberFormat('es-CO', {
          style: 'currency',
          currency: 'COP',
          minimumFractionDigits: 0,
          maximumFractionDigits: 0
        }).format(commission.commission_amount);

        await createUserNotification(
          supabaseAdmin,
          tenantId,
          commission.user_id,
          'commission_voided',
          'Comisión Anulada',
          `Una comisión por ${formattedAmount} fue anulada. Motivo: "${reason}"`,
          `/staff/commissions` // Link to the commissions page
        );

        responseData = { success: true, commission: updatedCommission };
        break;
      }

      // --- COMMISSION MATRIX ACTIONS ---

      // --- COMMISSION MATRIX ACTIONS ---
      case 'get_product_commission_matrix': {
        const { productId } = payload;
        if (!productId) throw new Error('Product ID is required.');
        
        const { data, error } = await supabaseAdmin.rpc('get_product_commission_matrix', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_product_id: productId
        });

        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get_service_commission_matrix': {
        const { serviceId } = payload;
        if (!serviceId) throw new Error('Service ID is required.');

        const { data, error } = await supabaseAdmin.rpc('get_service_commission_matrix', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_service_id: serviceId
        });

        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get_user_product_commission_matrix': {
        const { userId: targetUserId } = payload;
        if (!targetUserId) throw new Error('User ID is required.');
        
        const { data, error } = await supabaseAdmin.rpc('get_user_product_commission_matrix', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_user_id: targetUserId
        });

        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get_user_service_commission_matrix': {
        const { userId: targetUserId } = payload;
        if (!targetUserId) throw new Error('User ID is required.');

        const { data, error } = await supabaseAdmin.rpc('get_user_service_commission_matrix', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_user_id: targetUserId
        });

        if (error) throw error;
        responseData = data;
        break;
      }

      case 'update_commission': {
        const {
          item_id,
          user_id,
          branch_id,
          item_type,
          commission_rate,
          can_perform
        } = payload;

        if (!item_id || !user_id || !branch_id || !item_type) {
          throw new Error('Missing required fields for commission update.');
        }

        let data, error;

        if (item_type === 'product') {
          ({ data, error } = await supabaseAdmin
            .from('product_user_commissions')
            .upsert(
              {
                product_id: item_id,
                user_id: user_id,
                branch_id: branch_id,
                tenant_id: tenantId,
                platform_id: platformId,
                commission_rate: commission_rate,
              },
              {
                onConflict: 'product_id, user_id, branch_id, tenant_id, platform_id',
              }
            )
            .select()
            .single());
        } else if (item_type === 'service') {
          ({ data, error } = await supabaseAdmin
            .from('service_user_commissions')
            .upsert(
              {
                service_id: item_id,
                user_id: user_id,
                branch_id: branch_id,
                tenant_id: tenantId,
                platform_id: platformId,
                commission_rate: commission_rate,
                can_perform: can_perform ?? false,
              },
              {
                onConflict: 'service_id, user_id, branch_id, tenant_id, platform_id',
              }
            )
            .select()
            .single());
        } else {
          throw new Error(`Invalid item_type: ${item_type}`);
        }

        if (error) throw error;
        responseData = data;
        break;
      }

      case 'create_product_transfer_request': {
        const { requesting_branch_id, origin_branch_id, notes, items } = payload;
        responseData = await callRpc(supabaseAdmin, 'create_product_transfer_request', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_requesting_branch_id: requesting_branch_id,
          p_origin_branch_id: origin_branch_id,
          p_notes: notes,
          p_items: items,
        });
        break;
      }

      case 'approve_product_transfer': {
        const { transfer_id, adjusted_items } = payload;
        responseData = await callRpc(supabaseAdmin, 'approve_product_transfer', {
          p_transfer_id: transfer_id,
          p_adjusted_items: adjusted_items,
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_user_id: userId,
        });
        break;
      }

      case 'reject_product_transfer': {
        const { transfer_id } = payload;
        responseData = await callRpc(supabaseAdmin, 'reject_product_transfer', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_transfer_id: transfer_id,
        });
        break;
      }

      case 'ship_product_transfer': {
        const { transfer_id } = payload;
        responseData = await callRpc(supabaseAdmin, 'ship_product_transfer', {
          p_transfer_id: transfer_id,
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_user_id: userId,
        });
        break;
      }

      case 'receive_product_transfer': {
        const { transfer_id, reception_notes, received_items } = payload;
        responseData = await callRpc(supabaseAdmin, 'receive_product_transfer', {
          p_transfer_id: transfer_id,
          p_reception_notes: reception_notes,
          p_received_items: received_items,
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_user_id: userId,
        });
        break;
      }

      case 'cancel_product_transfer': {
        const { transfer_id } = payload;
        responseData = await callRpc(supabaseAdmin, 'cancel_product_transfer', {
          p_transfer_id: transfer_id,
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_user_id: userId,
        });
        break;
      }

      case 'get_transfer_details': {
        const { transfer_id } = payload;
        responseData = await callRpc(supabaseAdmin, 'get_transfer_details', {
          p_transfer_id: transfer_id,
          p_tenant_id: tenantId,
          p_platform_id: platformId,
        });
        break;
      }

      case 'get_branch_commission_matrix': {
        const { branchId } = payload;
        if (!branchId) {
          throw new Error('Branch ID is required for get_branch_commission_matrix.');
        }
        
        const { data, error } = await supabaseAdmin.rpc('get_branch_commission_matrix', {
          tenant_id_param: tenantId,
          platform_id_param: platformId,
          branch_id_param: branchId,
        });

        if (error) throw error;
        responseData = data;
        break;
      }

      case 'GET_SUBSCRIPTION_STATUS': {
        if (!tenantId) {
          throw new Error('Tenant ID is required to get subscription status.');
        }

        // 1. Get plan limits from Core
        const coreSupabase = getCoreSupabaseClient();
        const { data: limitsData, error: limitsError } = await coreSupabase.rpc('get_tenant_plan_limits', {
          p_tenant_id: tenantId,
          p_platform_id: platformId
        });

        if (limitsError) {
          console.error('Error fetching plan limits from Core:', limitsError);
          throw new Error(`Failed to fetch subscription status: ${limitsError.message}`);
        }

        // 2. Get local usage (Active Branches) from Services DB
        const { count: activeBranchesCount, error: countError } = await supabaseAdmin
          .from('branches')
          .select('*', { count: 'exact', head: true })
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .eq('status', 'active');

        if (countError) {
           console.error('Error fetching active branches count:', countError);
        }

        // 3. Get total users count from Services DB
        const { count: usersCount, error: usersError } = await supabaseAdmin
            .from('user_assignments')
            .select('*', { count: 'exact', head: true })
            .eq('tenant_id', tenantId)
            .eq('platform_id', platformId);
        
        if (usersError) {
            console.error('Error fetching users count:', usersError);
        }

        // 4. Combine results
        const planInfo = Array.isArray(limitsData) ? limitsData[0] : limitsData;

        if (!planInfo) {
             // Fallback minimal object if RPC returns empty (e.g. error handled inside RPC)
             responseData = {
                plan_name: 'Desconocido',
                status: 'error',
                current_branches: activeBranchesCount || 0,
                current_users: usersCount || 0,
                max_branches: 0,
                max_users: 0
             };
        } else {
            responseData = {
                ...planInfo,
                current_branches: activeBranchesCount || 0,
                current_users: usersCount || 0
            };
        }
        break;
      }

      case 'start_attention_service': {
        const { serviceId } = payload;
        if (!serviceId) {
          throw new Error('serviceId (attention_service_id) is required to start a service.');
        }

        // Llama a la función RPC que ya existe en la base de datos
        const { error } = await supabaseAdmin.rpc('start_service', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_attention_service_id: serviceId
        });

        if (error) {
          console.error('Error calling start_service RPC:', error);
          throw error;
        }
        
        responseData = { success: true, message: 'Servicio iniciado correctamente.' };
        break;
      }

      case 'finish_attention_service': {
        const { serviceId } = payload;
        if (!serviceId) {
          throw new Error('serviceId (attention_service_id) is required to finish a service.');
        }

        // Llama a la función RPC que ya existe en la base de datos
        const { error } = await supabaseAdmin.rpc('end_service', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_attention_service_id: serviceId
        });

        if (error) {
          console.error('Error calling end_service RPC:', error);
          throw error;
        }
        
        responseData = { success: true, message: 'Servicio finalizado correctamente.' };
        break;
      }

      case 'call_client_for_service': {
        const { serviceId } = payload; // This is attention_service_id
        if (!serviceId) {
          throw new Error('serviceId (attention_service_id) is required to call a client.');
        }

        // 1. Get attention details from the serviceId
        const { data: attentionService, error: serviceError } = await supabaseAdmin
          .from('attention_services')
          .select(`
            user_id,
            attention_id,
            attentions (
              branch_id,
              client_id
            )
          `)
          .eq('id', serviceId)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .single();

        if (serviceError) throw new Error(`Error fetching attention details: ${serviceError.message}`);
        if (!attentionService) throw new Error(`Attention service with ID ${serviceId} not found.`);

        const { user_id: stylist_id, attention_id, attentions } = attentionService;
        const { branch_id, client_id } = attentions;

        if (!stylist_id || !branch_id || !client_id) {
          throw new Error('Could not determine stylist, branch, or client from the attention service.');
        }

        // 2. Insert a new record into the turns table
        const { error: turnError } = await supabaseAdmin
          .from('turns')
          .insert({
            tenant_id: tenantId, // tenantId is available from the JWT
            platform_id: platformId,
            branch_id,
            client_id,
            stylist_id,
            attention_id,
            status: 'called', // Assuming 'called' is a valid status
            called_at: new Date().toISOString()
          });

        if (turnError) {
          console.error('Error creating turn:', turnError);
          throw new Error(`Could not create turn: ${turnError.message}`);
        }

        responseData = { success: true, message: 'Cliente llamado a la TV correctamente.' };
        break;
      }

      case 'create_branch': {
        const { data, error } = await supabaseAdmin.rpc('create_branch', {
          p_tenant_id: tenantId, // Aseguramos el tenant_id del usuario autenticado
          p_platform_id: platformId, // Pasamos el platform_id del usuario autenticado
          ...payload
        });

        if (error) {
          console.error('Error calling create_branch RPC:', error);
          throw error;
        }
        
        responseData = data;
        break;
      }

      case 'update_branch': {
        const { data, error } = await supabaseAdmin.rpc('update_branch', {
          p_tenant_id: tenantId, // Aseguramos el tenant_id del usuario autenticado
          p_platform_id: platformId, // Pasamos el platform_id del usuario autenticado
          ...payload
        });

        if (error) {
          console.error('Error calling update_branch RPC:', error);
          throw error;
        }
        
        responseData = data;
        break;
      }

      case 'update_equipment_maintenance_record': {
        const { recordId, updates } = payload;
        if (!recordId || !updates) {
          throw new Error('recordId and updates are required.');
        }

        const { error } = await supabaseAdmin.rpc('update_equipment_maintenance_record', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_record_id: recordId,
          p_updates: updates
        });

        if (error) {
          console.error('Error calling update_equipment_maintenance_record RPC:', error);
          throw error;
        }
        
        responseData = { success: true, message: 'Registro de mantenimiento actualizado.' };
        break;
      }

      case 'delete_equipment_maintenance_record': {
        const { recordId } = payload;
        if (!recordId) {
          throw new Error('recordId is required.');
        }

        const { error } = await supabaseAdmin.rpc('delete_equipment_maintenance_record', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_record_id: recordId
        });

        if (error) {
          console.error('Error calling delete_equipment_maintenance_record RPC:', error);
          throw error;
        }
        
        responseData = { success: true, message: 'Registro de mantenimiento eliminado.' };
        break;
      }

      case 'get_product_sellers': {
        const { productId, branchId, tenantId: payloadTenantId } = payload;
        if (!productId || !branchId || !payloadTenantId) {
          throw new Error('productId, branchId, and tenantId are required.');
        }

        const { data, error } = await supabaseAdmin.rpc('get_product_sellers', {
          p_tenant_id: payloadTenantId,
          p_platform_id: platformId,
          p_product_id: productId,
          p_branch_id: branchId
        });

        if (error) {
          console.error('Error calling get_product_sellers RPC:', error);
          throw error;
        }
        
        responseData = data;
        break;
      }

      case 'get_master_combos': {
        const { data, error } = await supabaseAdmin
          .from('combos')
          .select(`
            *,
            combo_items (
              *,
              product:products (name),
              service:services (name)
            ),
            combo_images:combo_images(*)
          `)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .order('name')
          .order('sort_order', { foreignTable: 'combo_images', ascending: true });

        if (error) {
          console.error('Error fetching master combos:', error);
          throw error;
        }
        
        responseData = data;
        break;
      }

      case 'update_combo_branch_prices': {
        const { combo_id, branch_id, price_overrides } = payload;
        if (!combo_id || !branch_id || !price_overrides) {
          throw new Error('combo_id, branch_id, and price_overrides are required.');
        }

        const { error } = await supabaseAdmin.rpc('update_combo_branch_prices', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_combo_id: combo_id,
          p_branch_id: branch_id,
          p_price_overrides: price_overrides
        });

        if (error) {
          console.error('Error calling update_combo_branch_prices RPC:', error);
          throw error;
        }
        
        responseData = { success: true, message: 'Precios de ítems del combo actualizados.' };
        break;
      }

      case 'update_tenant': {
        const { id, values } = payload;
        if (!id || !values) {
          throw new Error('Tenant ID and values are required for update.');
        }

        // Asegurarnos de que el tenant que se intenta actualizar es el mismo del token
        if (id !== tenantId) {
          throw new Error('Authorization error: You can only update your own tenant.');
        }

        let oldLogoFileId: string | null = null;

        console.log('[tenant-actions] update_tenant: Received values:', values);

        // If logo_url is being updated, get the old one first
        if (values.logo_url !== undefined) {
          console.log('[tenant-actions] update_tenant: logo_url is being updated. Fetching old value.');
          const { data: currentTenant, error: fetchError } = await coreSupabase
            .from('tenants')
            .select('logo_url')
            .eq('id', tenantId)
            .eq('platform_id', platformId)
            .single();
          
          if (fetchError) {
            console.error('[tenant-actions] update_tenant: Could not fetch current tenant to get old logo_url:', fetchError.message);
            // Don't block the update, just log the error
          } else if (currentTenant?.logo_url) {
            oldLogoFileId = currentTenant.logo_url;
            console.log('[tenant-actions] update_tenant: Found old logo_url:', oldLogoFileId);
          } else {
            console.log('[tenant-actions] update_tenant: currentTenant has no logo_url.');
          }
        }

        console.log('[tenant-actions] update_tenant: Performing update now.');
        const { data, error } = await coreSupabase
          .from('tenants')
          .update(values)
          .eq('id', tenantId)
          .eq('platform_id', platformId)
          .select()
          .single();

        if (error) {
          console.error('Error updating tenant:', error);
          throw error;
        }
        
        console.log('[tenant-actions] update_tenant: Value of oldLogoFileId before returning:', oldLogoFileId);
        responseData = { 
          success: true, 
          updatedTenant: data, 
          deletedFileId: oldLogoFileId 
        };
        break;
      }

      case 'update_attention_items': {
        const { p_payload } = payload;
        if (!p_payload) {
          throw new Error('p_payload is required.');
        }

        const { error } = await supabaseAdmin.rpc('update_attention_items', {
          p_payload
        });

        if (error) {
          console.error('Error calling update_attention_items RPC:', error);
          throw error;
        }
        
        responseData = { success: true, message: 'Ítems de la atención actualizados.' };
        break;
      }

      case 'GET_SUBSCRIPTION_PLANS': {
        const { tenantId: payloadTenantId } = payload;
        if (!payloadTenantId) {
          throw new Error('tenantId is required.');
        }

        // The RPC now lives in the Core DB and requires the platform_id.
        const { data, error } = await coreSupabase.rpc('get_subscription_plans_for_tenant', {
          p_tenant_id: payloadTenantId,
          p_platform_id: platformId // platformId is available from the JWT context
        });

        if (error) {
          console.error('Error calling get_subscription_plans_for_tenant RPC:', error);
          throw error;
        }
        
        responseData = data;
        break;
      }

      //case 'GET_PUBLIC_SUBSCRIPTION_PLANS': {
       // const { countryId, platformId } = payload;
        //if (!countryId || !platformId) {
          //throw new Error('countryId and platformId are required for GET_PUBLIC_SUBSCRIPTION_PLANS.');
        //}

        //const { data, error } = await supabaseAdmin.rpc('get_public_subscription_plans', {
          //p_country_id: countryId,
          //p_platform_id: platformId
        //});

        //if (error) {
          //console.error('Error calling get_public_subscription_plans RPC:', error);
          //throw error;
        //}
        
        //responseData = data;
        //break;
      //}

      case 'update_user_assignment': {
        const { assignmentId, updates } = payload;
        if (!assignmentId || !updates) {
          throw new Error('assignmentId and updates are required for update_user_assignment.');
        }

        console.log(`[update_user_assignment] Attempting to update assignment ${assignmentId} with:`, updates);

        // Security check is implicitly handled by RLS policies, but an explicit tenant_id check is safer.
        const { data, error } = await supabaseAdmin
          .from('user_assignments')
          .update(updates)
          .eq('id', assignmentId)
          .eq('tenant_id', tenantId) // Explicitly scope the update to the user's tenant
          .eq('platform_id', platformId) // Explicitly scope the update to the current platform
          .select()
          .single();

        if (error) {
          console.error('Error updating user assignment:', error);
          throw error;
        }
        responseData = data;
        break;
      }

      case 'insert_system_alert': {
        const { platform_id, type, message, details } = payload;
        if (!platform_id || !type || !message) {
          throw new Error('Platform ID, type, and message are required for inserting a system alert.');
        }
        const { data, error } = await supabaseAdmin
          .from('system_alerts')
          .insert({ platform_id: platform_id || platformId, type, message, details })
          .select()
          .single();
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'get-client-attentions': {
        const { client_id, page = 1, page_size = 10 } = payload;

        if (!client_id) {
          throw new Error('Client ID is required for get-client-attentions.');
        }

        const offset = (page - 1) * page_size;

        // 1. Fetch full attention objects
        const { data: attentions, error: attentionsError, count } = await supabaseAdmin
          .from('attentions')
          .select('*', { count: 'exact' }) // Select all fields
          .eq('client_id', client_id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .order('attention_datetime', { ascending: false })
          .range(offset, offset + page_size - 1);

        if (attentionsError) throw attentionsError;

        if (!attentions || attentions.length === 0) {
          responseData = { attentions: [], count: 0, page, page_size };
          break;
        }

        const attentionIds = attentions.map((a) => a.id);

        // 2. Fetch service details
        const { data: servicesDetails, error: servicesError } = await supabaseAdmin
          .from('attention_services')
          .select('*, services(name)') // Get all fields from attention_services + service name
          .in('attention_id', attentionIds)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId);

        if (servicesError) throw servicesError;

        const attentionServiceIds = (servicesDetails || []).map((s) => s.id);
        const userIds = [...new Set((servicesDetails || []).map((s) => s.user_id).filter(Boolean))];

        // 3. Fetch users
        let usersMap = new Map();
        if (userIds.length > 0) {
          const {
            data: { users },
            error: usersError,
          } = await supabaseAdmin.auth.admin.listUsers({ page: 1, perPage: 9999 });
          if (usersError) console.error('Error fetching users:', usersError);
          else {
            const relevantUsers = users.filter((u) => userIds.includes(u.id));
            usersMap = new Map(relevantUsers.map((u) => [u.id, u]));
          }
        }

        // 4. Fetch evidences
        let evidences = [];
        if (attentionServiceIds.length > 0) {
          const { data: evidencesData, error: evidencesError } = await supabaseAdmin
            .from('attention_service_evidences')
            .select('*')
            .in('attention_service_id', attentionServiceIds)
            .eq('tenant_id', tenantId)
            .eq('platform_id', platformId);
          if (evidencesError) console.error('Error fetching evidences:', evidencesError);
          else evidences = evidencesData;
        }

        // 5. Fetch consents
        let consents = [];
        const { data: consentsData, error: consentsError } = await supabaseAdmin
          .from('client_document_instances')
          .select('*, template: client_document_templates(name)')
          .in('attention_id', attentionIds)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId);
        if (consentsError) console.error('Error fetching consents:', consentsError);
        else consents = consentsData;

        // 6. Assemble the data
        const evidencesByServiceId = (evidences || []).reduce((acc, evidence) => {
          if (!acc[evidence.attention_service_id]) acc[evidence.attention_service_id] = [];
          acc[evidence.attention_service_id].push(evidence);
          return acc;
        }, {});

        const servicesByAttention = (servicesDetails || []).reduce((acc, detail) => {
          if (!acc[detail.attention_id]) acc[detail.attention_id] = [];

          const professionalData = usersMap.get(detail.user_id);
          const professionalMeta = professionalData?.user_metadata;
          const professionalName = professionalMeta
            ? `${professionalMeta.first_name || ''} ${professionalMeta.last_name || ''}`.trim()
            : 'N/A';

          let durationInMinutes = null;
          if (detail.start_time && detail.end_time) {
            const start = new Date(detail.start_time);
            const end = new Date(detail.end_time);
            if (!isNaN(start) && !isNaN(end)) {
              durationInMinutes = Math.round((end.getTime() - start.getTime()) / (1000 * 60));
            }
          }

          // Add extra computed fields to the service detail object
          const enrichedDetail = {
            ...detail,
            professional_name: professionalName,
            duration_minutes: durationInMinutes,
            attention_service_evidences: evidencesByServiceId[detail.id] || [],
          };

          acc[detail.attention_id].push(enrichedDetail);
          return acc;
        }, {});

        const consentsByAttention = (consents || []).reduce((acc, consent) => {
          if (!acc[consent.attention_id]) acc[consent.attention_id] = [];
          acc[consent.attention_id].push(consent);
          return acc;
        }, {});

        // Add the fetched details to the main attention objects
        const enrichedAttentions = attentions.map((attention) => ({
          ...attention,
          attention_services: servicesByAttention[attention.id] || [],
          client_document_instances: consentsByAttention[attention.id] || [],
        }));

        responseData = {
          attentions: enrichedAttentions,
          count: count,
          page: page,
          page_size: page_size
        };
        break;
      }
      case 'get_general_report': {
        const { p_date_from, p_date_to } = payload;
        if (!p_date_from || !p_date_to) throw new Error('Date range is required.');
        responseData = await supabaseAdmin.rpc('get_general_report', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_date_from: p_date_from,
          p_date_to: p_date_to,
        });
        break;
      }

      case 'get_service_report': {
        const { p_date_from, p_date_to } = payload;
        if (!p_date_from || !p_date_to) throw new Error('Date range is required.');
        responseData = await supabaseAdmin.rpc('get_service_report', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_date_from: p_date_from,
          p_date_to: p_date_to,
        });
        break;
      }

      case 'get_user_performance_report': {
        const { p_date_from, p_date_to } = payload;
        if (!p_date_from || !p_date_to) throw new Error('Date range is required.');
        responseData = await supabaseAdmin.rpc('get_user_performance_report', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_date_from: p_date_from,
          p_date_to: p_date_to,
        });
        break;
      }

      
      case 'confirm_attention': {
        const { p_attention_id } = payload;
        if (!p_attention_id) throw new Error('Attention ID is required.');

        // Call the RPC to update the attention status
        const { error } = await supabaseAdmin.rpc('confirm_attention', {
          p_attention_id,
          p_tenant_id: tenantId,
          p_platform_id: platformId
        });

        if (error) {
          console.error('Error calling confirm_attention RPC:', error);
          throw error;
        }

        responseData = { success: true, message: 'Atención confirmada exitosamente.' };
        break;
      }

      case 'reactivate_treatment_session': {
        const { p_session_id } = payload;
        if (!p_session_id) throw new Error('Session ID is required.');
        if (!tenantId) throw new Error('Tenant ID is required.');

        const { error } = await supabaseAdmin.rpc('reactivate_treatment_session', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_session_id: p_session_id,
        });

        if (error) {
          console.error('Error calling reactivate_treatment_session RPC:', error);
          throw error;
        }

        responseData = { success: true, message: 'Sesión de tratamiento reactivada.' };
        break;
      }

      case 'cancel_treatment_session': {
        const { p_session_id } = payload;
        if (!p_session_id) throw new Error('Session ID is required.');
        if (!tenantId) throw new Error('Tenant ID is required.');

        const { error } = await supabaseAdmin.rpc('cancel_treatment_session', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_session_id: p_session_id,
        });

        if (error) {
          console.error('Error calling cancel_treatment_session RPC:', error);
          throw error;
        }

        responseData = { success: true, message: 'Sesión de tratamiento cancelada.' };
        break;
      }

      // --- TREATMENT ACTIONS ---
      case 'list_treatments': {
        const { tenant_id, type, category_id, show_inactive } = payload;
        if (!tenant_id || !type) throw new Error('tenant_id and type are required.');
        
        console.log(`list_treatments called with: category_id=${category_id}, show_inactive=${show_inactive}`);

        responseData = await supabaseAdmin.rpc('list_treatments', {
          p_tenant_id: tenant_id,
          p_platform_id: platformId,
          p_type: type,
          p_category_id: category_id || null,
          p_show_inactive: show_inactive,
        });
        break;
      }

      case 'get_treatment_details': {
        const { treatment_id } = payload;
        if (!treatment_id) throw new Error('treatment_id is required.');

        responseData = await supabaseAdmin.rpc('get_treatment_details', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_treatment_id: treatment_id,
        });
        break;
      }

      case 'create_treatment': {
        const { name, description, type } = payload;
        if (!name || !type) {
          throw new Error('Name and type are required for creating a treatment.');
        }

        const { data, error } = await supabaseAdmin
          .from('treatments')
          .insert({
            tenant_id: tenantId,
            platform_id: platformId,
            name,
            description: description || null,
            type,
            upfront_price: 0,
            financed_price: 0,
          })
          .select()
          .single();
        
        if (error) throw error;
        responseData = data;
        break;
      }

      case 'update_treatment': {
        const { treatment_id, ...updates } = payload;
        if (!treatment_id) {
          throw new Error('Treatment ID is required.');
        }

        // If the update contains sessions, it's a full update from the main form.
        // We need to use the RPC to handle the complex nested inserts.
        if (updates.sessions) {
            console.log('Performing full treatment update via RPC...');
            const { name, description, upfront_price, financed_price, sessions } = updates;
            // The RPC expects all fields. We must ensure they exist, even if we pull them from the existing record.
            // However, the frontend form sends everything, so we can rely on that for now.
             if (name === undefined || upfront_price === undefined || financed_price === undefined) {
                throw new Error('Full update requires name, upfront_price, and financed_price.');
            }
            responseData = await supabaseAdmin.rpc('update_treatment', {
              p_tenant_id: tenantId,
              p_platform_id: platformId,
              p_treatment_id: treatment_id,
              p_name: name,
              p_description: description,
              p_upfront_price: upfront_price,
              p_financed_price: financed_price,
              p_sessions: sessions,
            });
        } else {
            // If there are no sessions, it's a simple, partial update (e.g., from the quick-edit dialog).
            console.log('Performing partial treatment update via table update...');
            const { data, error } = await supabaseAdmin
              .from('treatments')
              .update(updates)
              .eq('id', treatment_id)
              .eq('tenant_id', tenantId)
              .eq('platform_id', platformId)
              .select()
              .single();

            if (error) throw error;
            responseData = data;
        }
        break;
      }

      case 'delete_treatment': {
        const { treatment_id } = payload;
        if (!treatment_id) throw new Error('treatment_id is required.');
        responseData = await supabaseAdmin.rpc('delete_treatment', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_treatment_id: treatment_id,
        });
        break;
      }

      // --- TREATMENT IMAGE ACTIONS ---
      case 'get_treatment_images': {
        const { treatmentId } = payload;
        if (!treatmentId) throw new Error('Treatment ID is required.');
        
        const { data, error } = await supabaseAdmin
          .from('treatment_images')
          .select('*')
          .eq('treatment_id', treatmentId)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .order('is_primary', { ascending: false })
          .order('sort_order', { ascending: true });

        if (error) throw error;
        
        responseData = data || [];
        break;
      }

      case 'associate_treatment_image': {
        const { treatmentId, google_drive_file_id } = payload;
        if (!treatmentId || !google_drive_file_id) {
          throw new Error('treatmentId and google_drive_file_id are required.');
        }
        responseData = await callRpc(supabaseAdmin, 'associate_treatment_image', { 
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_treatment_id: treatmentId, 
          p_google_drive_file_id: google_drive_file_id 
        });
        break;
      }

      case 'delete_treatment_image': {
        const { imageId } = payload;
        if (!imageId) throw new Error('Image ID is required.');
        const google_drive_file_id = await supabaseAdmin.rpc('delete_treatment_image', { 
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_image_id: imageId 
        });
        if (google_drive_file_id) {
            supabaseAdmin.functions.invoke('google-drive-delete', {
                body: {
                    fileId: google_drive_file_id,
                    tenantId: tenantId,
                    platformId: platformId,
                    uploadContext: 'TreatmentImages',
                }
            });
        }
        responseData = { success: true };
        break;
      }

      case 'set_primary_treatment_image': {
        const { treatmentId, imageId } = payload;
        if (!treatmentId || !imageId) throw new Error('Treatment ID and Image ID are required.');

        responseData = await supabaseAdmin.rpc('set_primary_image_for_treatment', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_treatment_id: treatmentId,
          p_image_id: imageId,
        });
        break;
      }

      case 'update_treatment_images_order': {
        const { treatmentId, images_data } = payload;
        if (!treatmentId || !images_data) {
          throw new Error('treatmentId and images_data are required for update_treatment_images_order.');
        }
        responseData = await supabaseAdmin.rpc('update_treatment_images_order', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_treatment_id: treatmentId,
          p_images_data: images_data,
        });
        break;
      }

      // --- CLIENT TREATMENT ACTIONS ---
      case 'assign_treatment_to_client': {
        const { client_id, tenant_id, treatment_id, name, payment_type, final_price, start_date, sessions } = payload;
        if (!client_id || !tenant_id || !treatment_id || !name || !payment_type || !final_price || !start_date || !sessions) {
          throw new Error('client_id, tenant_id, treatment_id, name, payment_type, final_price, start_date, and sessions are required.');
        }
        responseData = await supabaseAdmin.rpc('assign_treatment_to_client', {
          p_tenant_id: tenant_id,
          p_platform_id: platformId,
          p_client_id: client_id,
          p_prototype_id: treatment_id, // Matches new RPC parameter name
          p_custom_name: name,         // New custom name parameter
          p_payment_type: payment_type, // Matches new RPC parameter name
          p_custom_final_price: final_price,
          p_start_date: start_date,
          p_sessions: sessions,
        });
        break;
      }

      case 'get_client_treatments': {
        const { client_id } = payload;
        if (!client_id) throw new Error('client_id is required.');
        responseData = await supabaseAdmin.rpc('get_client_treatments', { 
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_client_id: client_id 
        });
        break;
      }

      case 'get_client_treatment_details': {
        const { client_treatment_id } = payload;
        if (!client_treatment_id) throw new Error('client_treatment_id is required.');
        responseData = await supabaseAdmin.rpc('get_client_treatment_details', { 
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_client_treatment_id: client_treatment_id 
        });
        break;
      }

      case 'delete_client_treatment': {
        const { p_client_treatment_id } = payload;
        if (!p_client_treatment_id) {
          throw new Error('p_client_treatment_id is required.');
        }
        responseData = await supabaseAdmin.rpc('delete_client_treatment', {
          p_client_treatment_id: p_client_treatment_id,
          p_tenant_id: tenantId,
          p_platform_id: platformId,
        });
        break;
      }

      case 'complete_client_treatment_session': {
        const { session_id, attention_id } = payload;
        if (!session_id || !attention_id) throw new Error('session_id and attention_id are required.');
        responseData = await supabaseAdmin.rpc('complete_client_treatment_session', {
          p_session_id: session_id,
          p_attention_id: attention_id,
          p_tenant_id: tenantId,
          p_platform_id: platformId,
        });
        break;
      }

      case 'get_stock_report': {
        const { p_date_from, p_date_to } = payload;
        if (!p_date_from || !p_date_to) throw new Error('Date range is required for stock report.');
        responseData = await supabaseAdmin.rpc('get_stock_report', {
          p_tenant_id: tenantId,
          p_platform_id: platformId,
          p_date_from: p_date_from,
          p_date_to: p_date_to,
        });
        break;
      }

      case 'get_unified_history': {
        const { resource_type, resource_id } = payload;
        if (!resource_type || !resource_id) throw new Error('resource_type and resource_id are required.');

        const coreSupabase = getCoreSupabaseClient();

        // 1. Fetch Local Comments
        const { data: comments, error: commentsError } = await supabaseAdmin
          .from('chatter_comments')
          .select('id, comment_text, created_at, user_id')
          .eq('resource_type', resource_type)
          .eq('resource_id', resource_id)
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .order('created_at', { ascending: false });

        if (commentsError) throw commentsError;

        // 2. Fetch Remote Audit Logs (Core)
        const { data: logs, error: logsError } = await coreSupabase
          .from('audit_logs')
          .select('*')
          .eq('tenant_id', tenantId)
          .eq('platform_id', platformId)
          .eq('root_entity_type', resource_type)
          .eq('root_entity_id', resource_id)
          .order('created_at', { ascending: false });

        if (logsError) console.error('[History] Error fetching audit logs:', logsError);

        const safeLogs = logs || [];

        // 3. Resolve Avatars locally
        const userIds = new Set<string>();
        comments?.forEach((c: any) => { if (c.user_id) userIds.add(c.user_id); });
        safeLogs.forEach((l: any) => { if (l.user_id) userIds.add(l.user_id); });

        const avatarMap = new Map<string, string>();
        if (userIds.size > 0) {
          const { data: avatars } = await supabaseAdmin
            .from('user_avatars')
            .select('user_id, google_drive_file_id')
            .in('user_id', Array.from(userIds))
            .eq('tenant_id', tenantId)
            .eq('platform_id', platformId);
          avatars?.forEach((a: any) => avatarMap.set(a.user_id, a.google_drive_file_id));
        }

        // 4. Merge and Format
        const unifiedFeed = [
          ...(comments || []).map((c: any) => ({
            id: c.id,
            type: 'comment',
            created_at: c.created_at,
            user: {
              id: c.user_id,
              full_name: 'Usuario', // Fallback as names are in auth.users
              avatar_url: avatarMap.get(c.user_id) || null
            },
            content: { text: c.comment_text }
          })),
          ...safeLogs.map((l: any) => ({
            id: l.id,
            type: 'audit_log',
            action: l.action,
            module: l.module,
            created_at: l.created_at,
            user: {
              id: l.user_id,
              full_name: l.user_name || 'Sistema',
              avatar_url: avatarMap.get(l.user_id) || null
            },
            content: {
              old_value: l.old_value,
              new_value: l.new_value,
              entity_type: l.entity_type
            }
          }))
        ];

        responseData = unifiedFeed.sort((a, b) =>
          new Date(b.created_at).getTime() - new Date(a.created_at).getTime()
        );
        break;
      }

      default:
        throw new Error(`Unknown action: ${action}`);
    }

    return new Response(JSON.stringify(responseData), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: status,
    });
  } catch (error) {
    status = 500;
    console.error("Error in tenant-actions Edge Function (raw):", error);
    console.error("Error in tenant-actions Edge Function (JSON):", JSON.stringify(error, null, 2));
    console.error("Error in tenant-actions Edge Function (typeof):", typeof error);
    console.error("Error in tenant-actions Edge Function (constructor):", error ? error.constructor.name : 'null/undefined');

    let errorMessage: string;
    if (error instanceof Error) {
      errorMessage = error.message;
    } else if (typeof error === 'object' && error !== null) {
      try {
        errorMessage = JSON.stringify(error);
      } catch (e) {
        errorMessage = 'An unknown object error occurred (stringify failed).';
      }
    } else {
      errorMessage = String(error);
    }

    if (!errorMessage || errorMessage === '{}' || errorMessage === 'null' || errorMessage === 'undefined' || errorMessage === '[object Object]') {
        errorMessage = 'An unexpected error occurred in the Edge Function. Check Supabase logs for details.';
    }

    return new Response(JSON.stringify({ error: errorMessage }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: status,
    });
  } finally {
    const endTime = performance.now();
    const duration = Math.round(endTime - startTime);
    
    try {
      const coreSupabase = getCoreSupabaseClient();
      const { error } = await coreSupabase.rpc('log_api_metric', {
        p_tenant_id: tenantId,
        p_platform_id: platformId,
        p_path: `edge/tenant-actions/${action}`,
        p_method: 'POST',
        p_status_code: status,
        p_response_time_ms: duration,
      });
      
      if (error) {
        console.error('[Metrics] Error logging metric to Core:', JSON.stringify(error, null, 2));
      }
    } catch (e) {
      console.error('[Metrics] Exception during metric logging:', e.message);
    }
  }
});
