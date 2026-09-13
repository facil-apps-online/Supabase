
import { getSupabaseAdminClient } from '../_shared/supabaseClients.ts';
import { corsHeaders } from '../_shared/cors.ts';
import { encrypt } from '../_shared/security.ts';
import { encode } from "https://deno.land/std@0.208.0/encoding/base64.ts";
import { createRemoteJWKSet, jwtVerify } from "npm:jose@5";
import { Sha256 } from 'https://deno.land/std@0.160.0/hash/sha256.ts';

console.log("Initializing core-actions function (refactored for distributed architecture)");

// Datos de negocio compartidos entre vendor_prospects y vendor_invitations (mismo set de
// campos que pide "Crear Tenant", menos las credenciales del admin) — capturados desde el
// primer contacto para no volver a digitarlos al invitar o dar de alta al cliente.
function extractBusinessFields(prospect: any) {
  return {
    legal_name: prospect?.legalName || null,
    whatsapp_phone: prospect?.whatsappPhone || null,
    billing_address: prospect?.billingAddress || null,
    einvoicing_email: prospect?.einvoicingEmail || null,
    physical_address_line1: prospect?.physicalAddressLine1 || null,
    physical_address_line2: prospect?.physicalAddressLine2 || null,
    physical_city: prospect?.physicalCity || null,
    physical_state: prospect?.physicalState || null,
    physical_postal_code: prospect?.physicalPostalCode || null,
    website: prospect?.website || null,
    latitude: prospect?.latitude ?? null,
    longitude: prospect?.longitude ?? null,
  };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  let action, payload;

  try {
    console.log('[core-actions] Request received. Method:', req.method);
    const bodyText = await req.text();
    console.log('[core-actions] Raw body:', bodyText);

    try {
      const jsonBody = JSON.parse(bodyText);
      action = jsonBody.action?.trim();
      payload = jsonBody.payload;
    } catch (e) {
      console.error('[core-actions] Failed to parse JSON body:', e);
      return new Response(JSON.stringify({ success: false, message: 'Invalid JSON body' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 400,
      });
    }

    console.log(`[core-actions] Parsed action: '${action}'`);

    const coreSupabase = getSupabaseAdminClient();

    // --- RBAC Configuration ---
    const actionRoleMap = {
      // Platform & Core Configuration (super_admin only)
      'create_platform': ['super_admin'],
      'update_platform': ['super_admin'],
      'delete_platform': ['super_admin'],
      'update_platform_settings': ['super_admin'],
      'create_currency': ['super_admin'],
      'update_currency': ['super_admin'],
      'delete_currency': ['super_admin'],
      'create_country': ['super_admin'],
      'update_country': ['super_admin'],
      'delete_country': ['super_admin'],
      'create_language': ['super_admin'],
      'update_language': ['super_admin'],
      'delete_language': ['super_admin'],
      'upsert_integration_provider': ['super_admin'],
      'delete_integration_category': ['super_admin'],
      'upsert_integration_category': ['super_admin'],
      'set_system_owner': ['super_admin'],
      
      // Platform/App Admins (app_super_admin)
      'create_user': ['super_admin', 'app_super_admin'],
      'get_tenants': ['super_admin', 'app_super_admin', 'comercial_admin'],
      'get_tenant_by_id': ['super_admin', 'app_super_admin', 'comercial_admin'],
      'get_subscriptions_by_tenant': ['super_admin', 'app_super_admin'],
      'get_tenant_integrations': ['super_admin', 'app_super_admin'],
      'save_whatsapp_integration': ['super_admin', 'app_super_admin'],
      'delete_tenant_integration': ['super_admin', 'app_super_admin'],
      
      // Subscription and Plan Management (can be app-level)
      'get_subscription_plans_by_platform': ['super_admin', 'app_super_admin'],
      'get_subscription_plan_by_id': ['super_admin', 'app_super_admin'],
      'create_subscription_plan': ['super_admin', 'app_super_admin'],
      'update_subscription_plan': ['super_admin', 'app_super_admin'],
      'get_plan_details': ['super_admin', 'app_super_admin'],
      'update_plan_details': ['super_admin', 'app_super_admin'],
      'get_tariffs_for_plan': ['super_admin', 'app_super_admin'],
      'schedule_new_tariff': ['super_admin', 'app_super_admin'],
      
      // Asset Management (can be app-level)
      'get_asset_purposes': ['super_admin', 'app_super_admin'],
      'create_asset_purpose': ['super_admin', 'app_super_admin'],
      'update_asset_purpose': ['super_admin', 'app_super_admin'],
      'delete_asset_purpose': ['super_admin', 'app_super_admin'],
      'get_plan_assets_by_platform': ['super_admin', 'app_super_admin'],
      'create_plan_asset': ['super_admin', 'app_super_admin'],
      'update_plan_asset': ['super_admin', 'app_super_admin'],
      'delete_plan_asset': ['super_admin', 'app_super_admin'],
      
      // Email Templates (can be app-level)
      'get_platform_email_templates': ['super_admin', 'app_super_admin'],
      'create_platform_email_template': ['super_admin', 'app_super_admin'],
      'update_platform_email_template': ['super_admin', 'app_super_admin'],
      'delete_platform_email_template': ['super_admin', 'app_super_admin'],
      
      // Investor Role
      'get_investor_dashboard_data': ['investor'],
    
      // System Health & Alerts
      'get_api_health_stats': ['super_admin', 'app_super_admin'],
      'get_infrastructure_metrics': ['super_admin', 'app_super_admin'],
      'insert_system_alert': ['super_admin', 'app_super_admin'],
      'get_system_alerts': ['super_admin', 'app_super_admin'],
      'update_system_alert_status': ['super_admin', 'app_super_admin'],
      
      // User & Assignment Management
      'get_tenant_users': ['super_admin', 'app_super_admin'],
      'get_platform_level_assignments': ['super_admin', 'app_super_admin'],
      'assign_platform_role': ['super_admin', 'app_super_admin'],
      'remove_platform_assignment': ['super_admin', 'app_super_admin'],
      'update_investor_stake': ['super_admin'],
      'assign_super_admin_role': ['super_admin'],
      'assign_vendor_role': ['super_admin', 'app_super_admin', 'comercial_admin'],
      'remove_vendor_tenant_assignment': ['super_admin', 'app_super_admin', 'comercial_admin'],
      'get_tenant_vendor_assignment': ['super_admin', 'app_super_admin', 'comercial_admin'],
      'assign_vendor_platform_commissions': ['super_admin', 'app_super_admin', 'comercial_admin'],
      'create_vendor_invitation': ['super_admin', 'app_super_admin', 'comercial_admin', 'vendor'],
      'get_platform_trial_plan': ['super_admin', 'app_super_admin', 'comercial_admin', 'vendor'],
      'list_vendor_invitations': ['super_admin', 'app_super_admin', 'comercial_admin', 'vendor'],
      'update_vendor_invitation_status': ['super_admin', 'app_super_admin', 'comercial_admin', 'vendor'],
      'delete_vendor_invitation': ['super_admin', 'app_super_admin', 'comercial_admin', 'vendor'],
      'get_vendor_invitation_funnel': ['super_admin', 'app_super_admin', 'comercial_admin', 'vendor'],
      'invite_superadmin_team_member': ['super_admin', 'app_super_admin', 'comercial_admin'],
      'create_vendor_prospect': ['super_admin', 'app_super_admin', 'comercial_admin', 'vendor'],
      'update_vendor_prospect': ['super_admin', 'app_super_admin', 'comercial_admin', 'vendor'],
      'get_vendor_conversion_report': ['super_admin', 'app_super_admin', 'comercial_admin', 'vendor'],
      'list_vendor_prospects': ['super_admin', 'app_super_admin', 'comercial_admin', 'vendor'],
      'delete_vendor_prospect': ['super_admin', 'app_super_admin', 'comercial_admin', 'vendor'],
      'log_vendor_prospect_visit': ['super_admin', 'app_super_admin', 'comercial_admin', 'vendor'],
      'list_vendor_prospect_visits': ['super_admin', 'app_super_admin', 'comercial_admin', 'vendor'],
      'convert_vendor_prospect_to_invitation': ['super_admin', 'app_super_admin', 'comercial_admin', 'vendor'],
      'delete_user': ['super_admin'],
                'update_user_name': ['super_admin', 'app_super_admin'],
                'get_vendor_platform_commissions': ['super_admin', 'app_super_admin', 'vendor'],
                'update_vendor_platform_commission': ['super_admin', 'app_super_admin'],
                'remove_vendor_platform_commission': ['super_admin', 'app_super_admin'],
                'get_platforms_stats': ['super_admin', 'app_super_admin', 'investor', 'vendor', 'comercial_admin'],
                'get_superadmin_payment_stats': ['super_admin', 'app_super_admin', 'investor', 'vendor', 'comercial_admin'],
                'get_countries_for_platform': ['super_admin', 'app_super_admin'],
                'assign_country_to_platform': ['super_admin', 'app_super_admin'],
                'remove_country_from_platform': ['super_admin', 'app_super_admin'],
      'clone_platform_configuration': ['super_admin'],
      'get_billing_entity': ['super_admin'],
      'upsert_billing_entity': ['super_admin'],
      
      // General Read Actions for any authenticated user of the superadmin portal
      'get_platforms': ['super_admin', 'app_super_admin', 'investor', 'vendor', 'comercial_admin'],
      'get_platform_by_id': ['super_admin', 'app_super_admin', 'investor', 'vendor', 'comercial_admin'],
      'get_currencies': ['super_admin', 'app_super_admin', 'investor', 'vendor', 'comercial_admin'],
      'get_countries': ['super_admin', 'app_super_admin', 'investor', 'vendor', 'comercial_admin'],
      'get_languages': ['super_admin', 'app_super_admin', 'investor', 'vendor', 'comercial_admin'],
      'get_global_integrations': ['super_admin', 'app_super_admin'],
      'get_integration_provider': ['super_admin', 'app_super_admin'],
      'get_integration_http_methods': ['super_admin', 'app_super_admin'],
      'get_integration_body_formats': ['super_admin', 'app_super_admin'],
      'get_integration_auth_methods': ['super_admin', 'app_super_admin'],
      'get_integration_categories': ['super_admin', 'app_super_admin'],
      'get_platform_categories': ['super_admin', 'app_super_admin'],
    
      // Tenant-facing Subscription Actions (public - validated via tenantId in payload)
      'get_subscription_status': ['public'],
      'get_tenant_subscription_plans': ['public'],
      'get_subscription_usage': ['public'],
      'activate_subscription': ['public'],
      'generate_wompi_checkout': ['public'],
      
      // Public Actions - No authentication required
      'check_superadmin_exists': ['public'],
      'get-google-auth-url': ['public'],
      'get_tenant_integration': ['public'],
      'delete_tenant_integration': ['public'],
      'create_first_superadmin': ['public'],
      
      // Internal Service Actions - Requires internal secret
      'get_google_drive_service_token': ['service_worker'],
    };
    
    // Default role if an action is not in the map
    const defaultRequiredRoles = ['super_admin'];
    
    const publicActions = Object.entries(actionRoleMap)
      .filter(([, roles]) => roles.includes('public'))
      .map(([action]) => action);

    const internalServiceActions = Object.entries(actionRoleMap)
      .filter(([, roles]) => roles.includes('service_worker'))
      .map(([action]) => action);

    // --- Authorization & Role-Based Access Control ---
    let callerUserId: string | null = null;
    let callerRoles: string[] = [];

    if (internalServiceActions.includes(action)) {
      const internalSecret = req.headers.get('X-Internal-Service-Secret');
      const expectedSecret = Deno.env.get('INTERNAL_SERVICE_SECRET');
      if (!internalSecret || internalSecret !== expectedSecret) {
        console.warn(`[core-actions] Unauthorized internal service access attempt for action '${action}'.`);
        return new Response(JSON.stringify({ success: false, message: 'Forbidden: Invalid internal service secret.' }), {
          status: 403,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }
      console.log(`[core-actions] Authorized internal service for action '${action}'.`);
    } else if (!publicActions.includes(action)) {
      const authHeader = req.headers.get('Authorization');
      if (!authHeader) {
        return new Response(JSON.stringify({ success: false, message: 'Authorization header is required.' }), {
          status: 401,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      try {
        const token = authHeader.replace('Bearer ', '');
        const supabaseUrl = Deno.env.get('SUPABASE_URL') || Deno.env.get('VITE_SUPABASE_URL');

        if (!supabaseUrl) {
          throw new Error("SUPABASE_URL or VITE_SUPABASE_URL must be set in the function's environment variables.");
        }
        
        const jwksUrl = new URL(`${new URL(supabaseUrl).origin}/auth/v1/.well-known/jwks.json`);
        console.log(`[core-actions] Attempting to fetch JWKS from: ${jwksUrl.href}`); // Diagnostic log
        const JWKS = createRemoteJWKSet(jwksUrl);
        const { payload: decodedToken } = await jwtVerify(token, JWKS);

        if (!decodedToken) {
          throw new Error("Invalid token payload.");
        }

        const userRoles = (decodedToken?.app_metadata?.assignments || []).map((a: any) => a.role);
        const userId = decodedToken?.sub;
        callerUserId = userId ?? null;
        callerRoles = userRoles;

        // super_admin can do anything
        if (userRoles.includes('super_admin')) {
            console.log(`[core-actions] User ${userId} authorized as super_admin for action '${action}'.`);
        } else {
            const requiredRoles = actionRoleMap[action] || defaultRequiredRoles;
            const hasPermission = userRoles.some((userRole: string) => requiredRoles.includes(userRole));
    
            if (!hasPermission) {
                console.warn(`[core-actions] Unauthorized access attempt by user ${userId} for action '${action}'. User Roles: [${userRoles.join(', ')}], Required: [${requiredRoles.join(', ')}]`);
                return new Response(JSON.stringify({ success: false, message: 'Forbidden: You do not have the necessary permissions for this action.' }), {
                    status: 403,
                    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
                });
            }
            console.log(`[core-actions] User ${userId} authorized for action '${action}' with roles [${userRoles.join(', ')}].`);
        }

      } catch (authError) {
        console.error('[core-actions] Auth Error:', authError.message);
        const errorMessage = authError.code === 'ERR_JWT_EXPIRED' ? 'Token has expired' : authError.message;
        return new Response(JSON.stringify({ success: false, message: 'Authentication failed: ' + errorMessage }), {
          status: 401,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }
    }
    // --- End Authorization ---

    let responseData: any;
    let statusCode = 200;
    const startTime = performance.now();
    let metricsPath = `edge/core-actions/${action}`;

    try {
      console.log(`[core-actions] Entering main switch for action: '${action}'`);
      switch (action) {

        case 'check_superadmin_exists': {
          console.log("[core-actions] Matched action: 'check_superadmin_exists'");
          const { data, error } = await coreSupabase.rpc('check_superadmin_exists');
          if (error) throw error;
          responseData = data;
          break;
        }

        case 'create_first_superadmin': {
          console.log("[core-actions] Matched action: 'create_first_superadmin'");
          const { data: existsData, error: existsError } = await coreSupabase.rpc('check_superadmin_exists');
          if (existsError) throw existsError;
          if (existsData === true) {
            throw new Error('Ya existe un superadministrador en el sistema. Acción denegada.');
          }

          const { email, password, fullName, firstName: payloadFirstName, lastName: payloadLastName } = payload;
          if (!email || !password || !fullName) {
            throw new Error('email, password y fullName son requeridos.');
          }

          const firstName = payloadFirstName || (fullName.split(' ')[0] || '');
          const lastName = payloadLastName || (fullName.split(' ').slice(1).join(' ') || '');
          
          const { data: newUser, error: createError } = await coreSupabase.auth.admin.createUser({
            email,
            password,
            email_confirm: true,
            user_metadata: { full_name: fullName, first_name: firstName, last_name: lastName },
            app_metadata: {
              assignments: [{ role: 'super_admin' }]
            }
          });

          if (createError) {
            throw createError;
          }
          
          responseData = { success: true, user: newUser.user };
          break;
        }

        case 'create_user': {
          console.log("[core-actions] Matched action: 'create_user'");
          // NOTA: este era el primero de dos 'case create_user' duplicados en este switch —
          // JS solo ejecuta el primero, así que el segundo (más abajo) estaba muerto y con él
          // la lógica que de verdad escribía platform_assignments/investor_platform_shares/
          // vendor_platform_commissions. Se fusionó aquí; el bloque muerto se eliminó.
          const { email, password, fullName, role, assignments, firstName: payloadFirstName, lastName: payloadLastName } = payload;
          if (!email || !password || !fullName || !role) {
            throw new Error('email, password, fullName, and role are required.');
          }

          const firstName = payloadFirstName || (fullName.split(' ')[0] || '');
          const lastName = payloadLastName || (fullName.split(' ').slice(1).join(' ') || '');

          const { data: newUser, error: createError } = await coreSupabase.auth.admin.createUser({
            email,
            password,
            email_confirm: true, // Auto-confirma el email
            user_metadata: { full_name: fullName, first_name: firstName, last_name: lastName },
            app_metadata: {
              assignments: [{ role: role }]
            }
          });

          if (createError) {
            throw createError;
          }

          const userId = newUser.user.id;

          if (assignments && assignments.length > 0) {
            if (role === 'app_super_admin' || role === 'comercial_admin') {
              const { data: roleData, error: roleError } = await coreSupabase.from('roles').select('id').eq('name', role).single();
              if (roleError) throw new Error(`Could not find role ${role}.`);
              const platformAssignments = assignments.map((platformId: string) => ({ user_id: userId, platform_id: platformId, role_id: roleData.id }));
              const { error } = await coreSupabase.from('platform_assignments').insert(platformAssignments);
              if (error) throw error;
            } else if (role === 'investor') {
              const investorData = assignments.map((a: any) => ({
                user_id: userId, platform_id: a.platformId, investment_share: a.stake / 100,
              }));
              const { error } = await coreSupabase.from('investor_platform_shares').insert(investorData);
              if (error) throw error;
            } else if (role === 'vendor') {
              const vendorData = assignments.map((platformId: string) => ({
                user_id: userId, platform_id: platformId,
              }));
              const { error } = await coreSupabase.from('vendor_platform_commissions').insert(vendorData);
              if (error) throw error;
            }
          }

          responseData = { success: true, user: newUser.user };
          break;
        }

        case 'get-google-auth-url': {
          console.log("[core-actions] Matched action: 'get-google-auth-url'");
          const { tenantId, provider, finalRedirectUrl } = payload;
          if (!tenantId || !provider || !finalRedirectUrl) {
            throw new Error('tenantId, provider, and finalRedirectUrl are required.');
          }

          const GOOGLE_CLIENT_ID = Deno.env.get('GOOGLE_CLIENT_ID');
          const REDIRECT_URI = `${Deno.env.get('SUPABASE_URL')}/functions/v1/google-oauth-callback`;
          
          if (!GOOGLE_CLIENT_ID) {
            throw new Error('GOOGLE_CLIENT_ID is not set.');
          }

          // The state object will be passed back to the callback
          const state = {
            tenantId,
            provider,
            finalRedirectUrl,
          };
          // We Base64-encode the state to prevent issues with special characters in the URL
          const encodedState = encode(JSON.stringify(state));

          const scopes = {
            google_drive: [
              'https://www.googleapis.com/auth/drive.file',
              'https://www.googleapis.com/auth/userinfo.email',
              'https://www.googleapis.com/auth/drive.readonly',
            ],
            google_gmail: [
              'https://www.googleapis.com/auth/gmail.send',
              'https://www.googleapis.com/auth/userinfo.email',
            ],
          };

          if (!scopes[provider]) {
            throw new Error(`Invalid provider: ${provider}`);
          }

          const authUrl = new URL('https://accounts.google.com/o/oauth2/v2/auth');
          authUrl.searchParams.set('client_id', GOOGLE_CLIENT_ID);
          authUrl.searchParams.set('redirect_uri', REDIRECT_URI);
          authUrl.searchParams.set('response_type', 'code');
          authUrl.searchParams.set('scope', scopes[provider].join(' '));
          authUrl.searchParams.set('access_type', 'offline');
          authUrl.searchParams.set('prompt', 'consent');
          authUrl.searchParams.set('state', encodedState);

          responseData = { authUrl: authUrl.toString() };
          break;
        }

        case 'get_google_drive_service_token': {
          console.log("[core-actions] Matched action: 'get_google_drive_service_token'");

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
          
          responseData = { access_token: tokens.access_token };
          break;
        }

        // --- Platform Actions (Refactored for Core DB) ---
        case 'get_platforms': {
          const { searchTerm } = payload || {};
          let query = coreSupabase.from('platforms').select('*');
          if (searchTerm) query = query.ilike('name', `%${searchTerm}%`);
          const { data, error } = await query.order('name');
          if (error) throw error;
          responseData = data;
          break;
        }
        case 'get_platform_by_id': {
          const { platformId } = payload;
          if (!platformId) throw new Error('platformId is required.');
          const { data, error } = await coreSupabase.from('platforms').select('*').eq('id', platformId).single();
          if (error) throw error;
          responseData = data;
          break;
        }
        case 'create_platform': {
          const { data, error } = await coreSupabase.from('platforms').insert(payload).select().single();
          if (error) throw error;
          responseData = data;
          break;
        }
        case 'update_platform': {
          const { id, ...platformData } = payload;
          if (!id) throw new Error('id is required for update.');
          const { data, error } = await coreSupabase.from('platforms').update(platformData).eq('id', id).select().single();
          if (error) throw error;
          responseData = data;
          break;
        }
        case 'delete_platform': {
          const { id } = payload;
          if (!id) throw new Error('id is required for delete.');
          const { error } = await coreSupabase.from('platforms').delete().eq('id', id);
          if (error) throw error;
          responseData = { success: true };
          break;
        }
        case 'update_platform_settings': {
          const { platformId, settings } = payload;
          if (!platformId || !settings) throw new Error('platformId and settings are required.');
          const { data, error } = await coreSupabase.from('platforms').update(settings).eq('id', platformId).select().single();
          if (error) throw error;
          responseData = data;
          break;
        }

        // --- Platform Countries Actions ---
        case 'get_countries_for_platform': {
          const { platformId } = payload;
          if (!platformId) throw new Error('platformId is required.');
          
          const { data, error } = await coreSupabase
            .from('platform_countries')
            .select('countries(*)')
            .eq('platform_id', platformId);

          if (error) throw error;
          
          // The result is [{ countries: {id, name, ...} }], so we map it.
          const countries = data.map(item => item.countries);
          responseData = countries.filter(Boolean); // Filter out any null/undefined results
          break;
        }
        case 'assign_country_to_platform': {
          const { platformId, countryId } = payload;
          if (!platformId || !countryId) throw new Error('platformId and countryId are required.');

          const { data, error } = await coreSupabase
            .from('platform_countries')
            .insert({ platform_id: platformId, country_id: countryId })
            .select();

          if (error) throw error;
          responseData = data;
          break;
        }
        case 'remove_country_from_platform': {
          const { platformId, countryId } = payload;
          if (!platformId || !countryId) throw new Error('platformId and countryId are required.');

          const { error } = await coreSupabase
            .from('platform_countries')
            .delete()
            .eq('platform_id', platformId)
            .eq('country_id', countryId);

          if (error) throw error;
          responseData = { success: true };
          break;
        }
        
        // --- System Catalogs (Refactored for Core DB) ---
        case 'get_currencies': {
          let query = coreSupabase.from('currencies').select('*');
          if (payload?.searchTerm) query = query.ilike('name', `%${searchTerm}%`);
          const { data, error } = await query.order('name');
          if (error) throw error;
          responseData = data;
          break;
        }
        case 'create_currency': {
          const { data, error } = await coreSupabase.from('currencies').insert(payload).select().single();
          if (error) throw error;
          responseData = data;
          break;
        }
        case 'update_currency': {
          const { id, ...updateData } = payload;
          if (!id) throw new Error('Currency ID is required.');
          const { data, error } = await coreSupabase.from('currencies').update(updateData).eq('id', id).select().single();
          if (error) throw error;
          responseData = data;
          break;
        }
        case 'delete_currency': {
          const { id } = payload;
          if (!id) throw new Error('Currency ID is required.');
          const { error } = await coreSupabase.from('currencies').delete().eq('id', id);
          if (error) throw error;
          responseData = { success: true };
          break;
        }
        case 'get_countries': {
          let query = coreSupabase.from('countries').select('*, currency:currencies(id, code, symbol)');
          if (payload?.searchTerm) query = query.ilike('name', `%${payload.searchTerm}%`);
          const { data, error } = await query.order('name');
          if (error) throw error;
          responseData = data;
          break;
        }
        case 'create_country': {
          const { data, error } = await coreSupabase.from('countries').insert(payload).select().single();
          if (error) throw error;
          responseData = data;
          break;
        }
        case 'update_country': {
          const { id, ...updateData } = payload;
          if (!id) throw new Error('Country ID is required.');
          const { data, error } = await coreSupabase.from('countries').update(updateData).eq('id', id).select().single();
          if (error) throw error;
          responseData = data;
          break;
        }
        case 'delete_country': {
          const { id } = payload;
          if (!id) throw new Error('Country ID is required.');
          const { error } = await coreSupabase.from('countries').delete().eq('id', id);
          if (error) throw error;
          responseData = { success: true };
          break;
        }
        case 'get_languages': {
          let query = coreSupabase.from('languages').select('*');
          if (payload?.searchTerm) query = query.ilike('name', `%${payload.searchTerm}%`);
          const { data, error } = await query.order('name');
          if (error) throw error;
          responseData = data;
          break;
        }
        case 'create_language': {
          const { data, error } = await coreSupabase.from('languages').insert(payload).select().single();
          if (error) throw error;
          responseData = data;
          break;
        }
        case 'update_language': {
          const { id, ...updateData } = payload;
          if (!id) throw new Error('Language ID is required.');
          const { data, error } = await coreSupabase.from('languages').update(updateData).eq('id', id).select().single();
          if (error) throw error;
          responseData = data;
          break;
        }
        case 'delete_language': {
          const { id } = payload;
          if (!id) throw new Error('Language ID is required.');
          const { error } = await coreSupabase.from('languages').delete().eq('id', id);
          if (error) throw error;
          responseData = { success: true };
          break;
        }

        // --- Subscription Plan Actions (Refactored for Core DB) ---
        case 'get_subscription_plans_by_platform': {
            const { platformId } = payload;
            if (!platformId) throw new Error('platformId is required.');
            const { data, error } = await coreSupabase
              .from('subscription_plans')
              .select('*')
              .eq('platform_id', platformId)
              .order('created_at', { ascending: false });
            if (error) throw error;
            responseData = data;
            break;
          }
  
          case 'get_subscription_plan_by_id': {
            const { planId } = payload;
            if (!planId) throw new Error('planId is required.');
            const { data, error } = await coreSupabase
              .from('subscription_plans')
              .select('*')
              .eq('id', planId)
              .single();
            if (error) throw error;
            responseData = data;
            break;
          }
  
          case 'create_subscription_plan': {
            const { planData } = payload;
            if (!planData || !planData.platform_id) throw new Error('Plan data with platform_id is required.');
            const { data, error } = await coreSupabase.from('subscription_plans').insert(planData).select().single();
            if (error) throw error;
            responseData = data;
            break;
          }
  
          case 'update_subscription_plan': {
            const { planId, planData } = payload;
            if (!planId || !planData) throw new Error('planId and planData are required.');
            const { data, error } = await coreSupabase.from('subscription_plans').update(planData).eq('id', planId).select().single();
            if (error) throw error;
            responseData = data;
            break;
          }
  
          // --- Asset Purpose Actions (Refactored for Core DB) ---
          case 'get_asset_purposes': {
            const { data, error } = await coreSupabase.from('asset_purposes').select('*').order('purpose_key', { ascending: true });
            if (error) throw error;
            responseData = data;
            break;
          }
          case 'create_asset_purpose': {
            const { purposeData } = payload;
            if (!purposeData) throw new Error('purposeData is required.');
            const { data, error } = await coreSupabase.from('asset_purposes').insert(purposeData).select().single();
            if (error) throw error;
            responseData = data;
            break;
          }
          case 'update_asset_purpose': {
            const { purposeId, purposeData } = payload;
            if (!purposeId || !purposeData) throw new Error('purposeId and purposeData are required.');
            const { data, error } = await coreSupabase.from('asset_purposes').update(purposeData).eq('id', purposeId).select().single();
            if (error) throw error;
            responseData = data;
            break;
          }
          case 'delete_asset_purpose': {
            const { purposeId } = payload;
            if (!purposeId) throw new Error('purposeId is required.');
            const { error } = await coreSupabase.from('asset_purposes').delete().eq('id', purposeId);
            if (error) throw error;
            responseData = { success: true };
            break;
          }
  
          // --- Plan Asset Actions (Refactored for Core DB) ---
          case 'get_plan_assets_by_platform': {
            const { platformId } = payload;
            if (!platformId) throw new Error('platformId is required.');
            const { data, error } = await coreSupabase.from('plan_assets').select('*, asset_purposes(purpose_key)').eq('platform_id', platformId).order('created_at', { ascending: false });
            if (error) throw error;
            responseData = data.map(asset => ({
              ...asset,
              asset_purpose_key: asset.asset_purposes?.purpose_key,
              asset_purposes: undefined,
            }));
            break;
          }
          case 'create_plan_asset': {
            const { assetData } = payload;
            if (!assetData || !assetData.platform_id) throw new Error('Asset data with platform_id is required.');
            const { data, error } = await coreSupabase.from('plan_assets').insert(assetData).select().single();
            if (error) throw error;
            responseData = data;
            break;
          }
          case 'update_plan_asset': {
            const { assetId, assetData } = payload;
            if (!assetId || !assetData) throw new Error('assetId and assetData are required.');
            const { data, error } = await coreSupabase.from('plan_assets').update(assetData).eq('id', assetId).select().single();
            if (error) throw error;
            responseData = data;
            break;
          }
          case 'delete_plan_asset': {
            const { assetId } = payload;
            if (!assetId) throw new Error('assetId is required.');
            const { error } = await coreSupabase.from('plan_assets').delete().eq('id', assetId);
            if (error) throw error;
            responseData = { success: true };
            break;
          }
  
          // --- Plan Configuration Actions (Country-Centric) (Refactored for Core DB) ---
          case 'get_plan_details': {
            const { planId } = payload;
            if (!planId) throw new Error('planId is required.');

            const { data: planData, error: planError } = await coreSupabase.from('subscription_plans').select('*, platforms(id, name)').eq('id', planId).single();
            if (planError) throw planError;

            const platformId = planData.platforms.id;
            const { data: platformCountries, error: countriesError } = await coreSupabase.from('countries').select('id, name, iso_code'); // Now directly from core countries
            if (countriesError) throw countriesError;
            
            const countries = platformCountries;
            const { data: countryConfigs, error: configsError } = await coreSupabase
              .from('plan_country_configurations')
              .select('*, plan_asset_limits(*, plan_assets(*), bonuses:plan_asset_bonuses(*))')
              .eq('plan_id', planId);
            if (configsError) throw configsError;

            const configurationsByCountry = {};
            for (const country of countries) {
              const config = countryConfigs.find(c => c.country_id === country.id);
              if (config) {
                configurationsByCountry[country.id] = {
                  ...config,
                  asset_limits: (config.plan_asset_limits || []).map(limit => ({
                    ...limit,
                    asset_name: limit.plan_assets?.name,
                    asset_description: limit.plan_assets?.description,
                    data_type: limit.plan_assets?.data_type,
                    bonuses: limit.bonuses || [],
                  }))
                };
              } else {
                configurationsByCountry[country.id] = {
                  id: null, plan_id: planId, country_id: country.id, is_active: false, features: [], asset_limits: []
                };
              }
            }
            responseData = { plan: planData, countries: countries, configurations: configurationsByCountry };
            break;
          }
          case 'update_plan_details': {
            const { planId, configurations } = payload;
            if (!planId || !configurations) throw new Error('planId and configurations are required.');

            for (const countryId in configurations) {
              const config = configurations[countryId];
              const hasFeatures = config.features && config.features.some(f => f.trim() !== '');
              const hasValuedLimits = config.asset_limits && config.asset_limits.some(l => l.value && String(l.value) !== '0' && String(l.value) !== 'false');
              
              if (!hasFeatures && !hasValuedLimits && !config.id) { // Nothing to insert if no data and no existing ID
                  continue;
              }

              if (!hasFeatures && !hasValuedLimits && config.id) { // Delete if no features/limits and it exists
                await coreSupabase.from('plan_country_configurations').delete().eq('id', config.id);
                continue;
              }
  
              const { data: upsertedConfig, error: upsertConfigError } = await coreSupabase
                .from('plan_country_configurations')
                .upsert({
                  id: config.id || undefined, plan_id: planId, country_id: countryId, is_active: true, features: config.features || [],
                })
                .select()
                .single();
              if (upsertConfigError) throw upsertConfigError;
              const planCountryConfigId = upsertedConfig.id;
  
              await coreSupabase.from('plan_asset_limits').delete().eq('plan_country_config_id', planCountryConfigId);
  
              if (config.asset_limits && config.asset_limits.length > 0) {
                const limitsToInsert = config.asset_limits
                  .filter((limit: any) => limit.asset_id && limit.value && String(limit.value) !== '0' && String(limit.value) !== 'false')
                  .map((limit: any) => ({
                    plan_country_config_id: planCountryConfigId, asset_id: limit.asset_id, value: String(limit.value),
                    extra_unit_price: limit.extra_unit_price || 0, overage_unit_price: limit.overage_unit_price || 0,
                  }));
  
                if (limitsToInsert.length > 0) {
                  const { data: insertedLimits, error: insertLimitsError } = await coreSupabase
                    .from('plan_asset_limits')
                    .insert(limitsToInsert)
                    .select('id, asset_id');
                  if (insertLimitsError) throw insertLimitsError;
  
                  const assetIdToLimitIdMap = new Map(insertedLimits.map(l => [l.asset_id, l.id]));
                  const bonusesToInsert: any[] = [];
  
                  for (const limit of config.asset_limits) {
                    if (limit.bonuses && limit.bonuses.length > 0) {
                      const sourceAssetLimitId = assetIdToLimitIdMap.get(limit.asset_id);
                      if (sourceAssetLimitId) {
                        for (const bonus of limit.bonuses) {
                          bonusesToInsert.push({
                            source_asset_limit_id: sourceAssetLimitId, bonus_asset_id: bonus.bonus_asset_id, quantity: bonus.quantity,
                          });
                        }
                      }
                    }
                  }
                  if (bonusesToInsert.length > 0) {
                    const { error: insertBonusesError } = await coreSupabase.from('plan_asset_bonuses').insert(bonusesToInsert);
                    if (insertBonusesError) throw insertBonusesError;
                  }
                }
              }
            }
            responseData = { success: true };
            break;
          }
  
          // --- Tariff Actions (New Versioned Pricing) (Refactored for Core DB) ---
          case 'get_tariffs_for_plan': {
            const { planId } = payload;
            if (!planId) throw new Error('planId is required.');
            
            const { data: tariffs, error: tariffsError } = await coreSupabase
              .from('price_tariffs')
              .select('*, currencies(code, symbol)')
              .eq('subscription_plan_id', planId)
              .order('effective_date', { ascending: false });
  
            if (tariffsError) throw tariffsError;
  
            const tariffsWithDetails = await Promise.all(
              tariffs.map(async (tariff) => {
                const { data: assetPrices, error: assetPricesError } = await coreSupabase
                  .from('tariff_asset_prices')
                  .select('*')
                  .eq('tariff_id', tariff.id);
                if (assetPricesError) throw assetPricesError;
                return { 
                    ...tariff, 
                    currency_code: tariff.currencies?.code,
                    currency_symbol: tariff.currencies?.symbol,
                    currencies: undefined,
                    asset_prices: assetPrices
                };
              })
            );
            responseData = tariffsWithDetails;
            break;
          }
  
          case 'schedule_new_tariff': {
            const { tariffData, assetPricesData } = payload;
            if (!tariffData || !assetPricesData) throw new Error('tariffData and assetPricesData are required.');
            const { data: newTariff, error: tariffError } = await coreSupabase
              .from('price_tariffs')
              .insert(tariffData)
              .select()
              .single();
            if (tariffError) throw tariffError;
            const pricesToInsert = assetPricesData.map((price: any) => ({
              ...price,
              tariff_id: newTariff.id,
            }));
            const { error: pricesError } = await coreSupabase
              .from('tariff_asset_prices')
              .insert(pricesToInsert);
            if (pricesError) {
              await coreSupabase.from('price_tariffs').delete().eq('id', newTariff.id);
              throw pricesError;
            }
            responseData = { success: true, tariff: newTariff };
            break;
          }


        // --- Tenant Actions (Refactored for Core DB where relevant, otherwise coreSupabase) ---
        case 'get_tenants': {
          const { searchTerm, platformId } = payload || {};
          let query = coreSupabase // Querying Core tenants table
            .from('tenants')
            .select(`
              id, name, slug, is_system_owner,
              platform:platforms(id, name),
              country:countries(id, name, iso_code)
            `);
          if (searchTerm) query = query.ilike('name', `%${searchTerm}%`);
          if (platformId) query = query.eq('platform_id', platformId);
          const { data, error } = await query.order('name');
          if (error) throw error;
          responseData = data;
          break;
        }

        case 'get_tenant_by_id': {
          const { id } = payload;
          if (!id) throw new Error('Tenant ID is required.');
          const { data: coreTenant, error: coreError } = await coreSupabase
            .from('tenants')
            .select(`
              *,
              platform:platforms(id, name),
              country:countries(id, name, iso_code)
            `)
            .eq('id', id)
            .single();
          if (coreError) throw coreError;
          responseData = coreTenant;
          break;
        }
        
        case 'set_system_owner': {
          const { tenantId, platformId } = payload || {};
          if (!tenantId || !platformId) throw new Error('tenantId and platformId are required.');
          // Update in Core DB's simplified tenants table
          const { error: coreUpdateError } = await coreSupabase.from('tenants').update({ is_system_owner: true }).eq('id', tenantId);
          if (coreUpdateError) throw coreUpdateError; // Propagate error

          // Also call RPC on Tenant DB to update its is_system_owner flag for backward compatibility
          // const { error: rpcError } = await coreSupabase.rpc('set_system_owner', { p_new_owner_tenant_id: tenantId, p_platform_id: platformId });
          // if (rpcError) console.error("Failed to update is_system_owner in Tenant DB via RPC:", rpcError); // Log, but don't block
          
          responseData = { success: true };
          break;
        }


        // --- Tenant Subscription Actions (Refactored for Core DB) ---
        case 'get_subscriptions_by_tenant': {
          const { tenantId } = payload;
          if (!tenantId) throw new Error('tenantId is required.');
          const { data, error } = await coreSupabase
            .from('tenant_subscriptions')
            .select(`
              id, start_date, end_date, is_active, is_trial,
              plan_country_configurations!inner(
                subscription_plans(name)
              )
            `)
            .eq('tenant_id', tenantId)
            .order('start_date', { ascending: false });
          if (error) throw error;
          responseData = data.map((sub: any) => {
            const status = sub.is_trial ? 'trial' : (sub.is_active ? 'active' : 'inactive');
            return {
              id: sub.id,
              start_date: sub.start_date,
              end_date: sub.end_date,
              is_active: sub.is_active,
              is_trial: sub.is_trial,
              plan_name: sub.plan_country_configurations?.subscription_plans?.name || 'N/A',
              status: status
            };
          });
          break;
        }

        // --- Email Template Actions (Refactored for Core DB) ---
        case 'get_platform_email_templates': {
            const { platformId } = payload;
            if (!platformId) throw new Error('platformId is required.');
            const { data, error } = await coreSupabase
              .from('email_templates')
              .select('*')
              .eq('platform_id', platformId);
            if (error) throw error;
            responseData = data;
            break;
          }
  
          case 'create_platform_email_template': {
            const { templateData } = payload; // ownerTenantId is not needed for Core DB
            if (!templateData) throw new Error('templateData is required.');
            const { data, error } = await coreSupabase
              .from('email_templates')
              .insert(templateData) // Insert directly
              .select()
              .single();
            if (error) throw error;
            responseData = data;
            break;
          }
  
          case 'update_platform_email_template': {
            const { templateId, templateData } = payload;
            if (!templateId || !templateData) throw new Error('templateId and templateData are required.');
            const { data, error } = await coreSupabase
              .from('email_templates')
              .update(templateData)
              .eq('id', templateId)
              .select()
              .single();
            if (error) throw error;
            responseData = data;
            break;
          }
  
          case 'delete_platform_email_template': {
            const { templateId } = payload;
            if (!templateId) throw new Error('templateId is required.');
            const { error } = await coreSupabase
              .from('email_templates')
              .delete()
              .eq('id', templateId);
            if (error) throw error;
            responseData = { success: true };
            break;
          }

        // --- Global Integrations Actions (Refactored for Core DB - defining integrations) ---
        case 'get_global_integrations': {
            const { data: providers, error: providersError } = await coreSupabase // integration_providers is Core
              .from('integration_providers')
              .select('*, category:integration_categories(id, name, slug)') // 'country' join removed here, as countries are now in Core
              .order('name');
            if (providersError) throw providersError;
            const { data: countries, error: countriesError } = await coreSupabase.from('countries').select('*').order('name'); // Countries is Core
            if (countriesError) throw countriesError;
            const { data: categories, error: categoriesError } = await coreSupabase.from('integration_categories').select('*').order('name'); // Categories is Core
            if (categoriesError) throw categoriesError;
            responseData = { providers, countries, categories };
            break;
          }
  
          case 'get_integration_provider': {
            const { id } = payload;
            if (!id) throw new Error('id is required.');
            const { data, error } = await coreSupabase // integration_providers is Core
              .from('integration_providers')
              .select('*, country:countries(id, name, iso_code), category:integration_categories(id, name, slug)')
              .eq('id', id)
              .single();
            if (error) throw error;
            responseData = data;
            break;
          }
  
          case 'upsert_integration_provider': {
            const { provider } = payload;
            if (!provider) throw new Error('provider is required.');
            const { data, error } = await coreSupabase // integration_providers is Core
              .from('integration_providers')
              .upsert(provider)
              .select()
              .single();
            if (error) throw error;
            responseData = data;
            break;
          }
  
          case 'get_integration_http_methods': {
            const { data, error } = await coreSupabase.from('integration_http_methods').select('*'); // Core DB
            if (error) throw error;
            responseData = data;
            break;
          }
  
          case 'get_integration_body_formats': {
            const { data, error } = await coreSupabase.from('integration_body_formats').select('*'); // Core DB
            if (error) throw error;
            responseData = data;
            break;
          }
  
          case 'get_integration_auth_methods': {
            const { data, error } = await coreSupabase.from('integration_auth_methods').select('*'); // Core DB
            if (error) throw error;
            responseData = data;
            break;
          }
  
          case 'get_integration_categories': {
            const { data, error } = await coreSupabase.from('integration_categories').select('*'); // Core DB
            if (error) throw error;
            responseData = data;
            break;
          }

          case 'get_platform_categories': {
            const { data, error } = await coreSupabase
              .from('platform_categories')
              .select(`
                id,
                slug,
                display_order,
                platform_category_translations (
                  locale,
                  name
                )
              `)
              .order('display_order', { ascending: true });
            if (error) throw error;
            responseData = data;
            break;
          }
  
          case 'delete_integration_category': {
            const { id } = payload;
            if (!id) throw new Error('id is required.');
            const { error } = await coreSupabase.from('integration_categories').delete().eq('id', id); // Core DB
            if (error) throw error;
            responseData = { success: true };
            break;
          }
  
          case 'upsert_integration_category': {
            const { category } = payload;
            if (!category) throw new Error('category is required.');
            const { data, error } = await coreSupabase.from('integration_categories').upsert(category).select().single(); // Core DB
            if (error) throw error;
            responseData = data;
            break;
          }

        // --- Tenant Integrations Actions (Refactored for Core DB) ---
        case 'get_tenant_integrations': {
          const { tenantId } = payload;
          if (!tenantId) throw new Error('tenantId is required.');

          // Step 1: Fetch all integrations for the tenant
          const { data: tenantIntegrations, error: tiError } = await coreSupabase
            .from('tenant_integrations')
            .select('*')
            .eq('tenant_id', tenantId);

          if (tiError) throw tiError;

          if (!tenantIntegrations || tenantIntegrations.length === 0) {
            responseData = [];
            break;
          }

          // Step 2: Fetch all real integration providers to enrich the data
          const { data: allProviders, error: pError } = await coreSupabase
            .from('integration_providers')
            .select('name, slug');
          
          if (pError) throw pError;

          // Create a map for easy lookup
          const providerMap = new Map(allProviders.map(p => [p.slug, p]));

          // Step 3: Manually enrich the tenant integrations
          const enrichedIntegrations = tenantIntegrations.map(integration => {
            const providerDetails = providerMap.get(integration.provider);
            return {
              ...integration,
              integration_providers: providerDetails ? { name: providerDetails.name, slug: providerDetails.slug } : null
            };
          });

          responseData = enrichedIntegrations;
          break;
        }

        case 'get_tenant_integration': {
          const { tenantId, provider } = payload;
          if (!tenantId || !provider) throw new Error('tenantId and provider are required.');

          const { data, error } = await coreSupabase
            .from('tenant_integrations')
            .select('*')
            .eq('tenant_id', tenantId)
            .eq('provider', provider)
            .maybeSingle();

          if (error) throw error;
          responseData = data || null;
          break;
        }

        case 'delete_tenant_integration': {
          const { tenantId, provider } = payload;
          if (!tenantId || !provider) throw new Error('tenantId and provider are required.');

          const { error } = await coreSupabase
            .from('tenant_integrations')
            .delete()
            .eq('tenant_id', tenantId)
            .eq('provider', provider);

          if (error) throw error;
          responseData = { success: true };
          break;
        }

        case 'save_whatsapp_integration': {
            const { tenant_id, credentials } = payload;
            if (!tenant_id || !credentials) throw new Error('tenant_id and credentials are required.');
            const { access_token, account_id, phone_number_id } = credentials;
            if (!access_token || !account_id || !phone_number_id) throw new Error('credentials must include access_token, account_id, and phone_number_id.');
            const { encrypted, nonce } = await encrypt(JSON.stringify(credentials));
            const { data, error } = await coreSupabase // Changed to coreSupabase
                .from('tenant_integrations')
                .upsert({ tenant_id: tenant_id, provider: 'meta_whatsapp', environment: 'production', encrypted_credentials: encrypted, nonce: nonce, is_active: true }, { onConflict: 'tenant_id, provider, environment' })
                .select()
                .single();
            if (error) throw error;
            responseData = { success: true, ...data };
            break;
        }

        case 'delete_tenant_integration': {
          const { integrationId } = payload;
          if (!integrationId) throw new Error('integrationId is required.');
          const { error } = await coreSupabase.from('tenant_integrations').delete().eq('id', integrationId); // Changed to coreSupabase
          if (error) throw error;
          responseData = { success: true };
          break;
        }


        case 'get_tenant_users': {
          const { tenantId } = payload;
          if (!tenantId) throw new Error('tenantId is required.');
          const { data, error } = await coreSupabase.rpc('get_tenant_users', { target_tenant_id: tenantId });
          if (error) throw error;
          responseData = data;
          break;
        }

        case 'get_platform_level_assignments': {
          const { data, error } = await coreSupabase.rpc('get_platform_level_assignments');
          if (error) throw error;
          responseData = data;
          break;
        }

        case 'assign_platform_role': {
          const { userId, role, assignments } = payload;
          if (!userId || !role || !assignments) throw new Error('userId, role, and assignments are required.');
          const { data: user, error: fetchError } = await coreSupabase.auth.admin.getUserById(userId);
          if (fetchError) throw fetchError;
          let existingAssignments = user.user.app_metadata?.assignments || [];

          if (role === 'investor') {
            const investorData = assignments.map((a: any) => ({
              user_id: userId, platform_id: a.platformId, investment_share: a.stake / 100,
            }));
            const { error } = await coreSupabase.from('investor_platform_shares').upsert(investorData);
            if (error) throw error;
            const newAssignment = assignments.map((a: any) => ({
              assignment_id: crypto.randomUUID(), tenant_id: null, tenant_name: null, role_id: null, role: 'investor', platform_id: a.platformId, platform_name: a.platform_name, branch_id: null, branch_name: null, status: 'active', stake_percentage: a.stake,
            }));
            existingAssignments = existingAssignments.filter((ea: any) => !(ea.role === 'investor' && newAssignment.some((na: any) => na.platform_id === ea.platform_id)));
            existingAssignments.push(...newAssignment);
          } else if (role === 'app_super_admin' || role === 'comercial_admin') {
            const { data: roleData, error: roleError } = await coreSupabase.from('roles').select('id').eq('name', role).single();
            if (roleError) throw new Error(`Could not find ${role} role.`);
            const roleId = roleData.id;
            const platformAssignments = assignments.map((a: any) => ({
              user_id: userId, platform_id: a.platformId, role_id: roleId,
            }));
            const { error } = await coreSupabase.from('platform_assignments').upsert(platformAssignments);
            if (error) throw error;
            const newAssignment = assignments.map((a: any) => ({
              assignment_id: crypto.randomUUID(), tenant_id: null, tenant_name: null, role_id: roleId, role: role, platform_id: a.platformId, platform_name: a.platform_name, branch_id: null, branch_name: null, status: 'active',
            }));
            existingAssignments = existingAssignments.filter((ea: any) => !(ea.role === role && newAssignment.some((na: any) => na.platform_id === ea.platform_id)));
            existingAssignments.push(...newAssignment);
          } else {
            throw new Error(`Role ${role} is not a platform-level role.`);
          }
          const { error: updateError } = await coreSupabase.auth.admin.updateUserById(userId, {
            app_metadata: { ...user.user.app_metadata, assignments: existingAssignments },
          });
          if (updateError) throw updateError;
          responseData = { success: true };
          break;
        }

        case 'remove_platform_assignment': {
            const { userId, role, platformId } = payload;
            if (!userId || !role || !platformId) throw new Error('userId, role, and platformId are required.');
            if (role === 'investor') {
                const { error } = await coreSupabase.from('investor_platform_shares').delete().match({ user_id: userId, platform_id: platformId });
                if (error) throw error;
            } else if (role === 'app_super_admin' || role === 'comercial_admin') {
                const { error } = await coreSupabase.from('platform_assignments').delete().match({ user_id: userId, platform_id: platformId });
                if (error) throw error;
            }
            const { data: user, error: fetchError } = await coreSupabase.auth.admin.getUserById(userId);
            if (fetchError) throw fetchError;
            const existingAssignments = user.user.app_metadata?.assignments || [];
            const finalAssignments = existingAssignments.filter((ea: any) => 
                !(ea.platform_id === platformId && ea.role === role)
            );
            const { error: updateError } = await coreSupabase.auth.admin.updateUserById(userId, {
                app_metadata: { ...user.user.app_metadata, assignments: finalAssignments },
            });
            if (updateError) throw updateError;
            responseData = { success: true };
            break;
        }

        case 'update_investor_stake': {
          const { userId, platformId, stake } = payload;
          if (!userId || !platformId || stake === undefined) throw new Error('userId, platformId, and stake are required.');
          const { error } = await coreSupabase.from('investor_platform_shares').update({ investment_share: stake / 100 }).match({ user_id: userId, platform_id: platformId });
          if (error) throw error;
          responseData = { success: true };
          break;
        }

        case 'assign_super_admin_role': {
          const { userId } = payload;
          if (!userId) throw new Error('userId is required.');
          const { data: roleData, error: roleError } = await coreSupabase.from('roles').select('id').eq('name', 'super_admin').single();
          if (roleError) throw new Error('Could not find super_admin role.');
          const { error: assignmentError } = await coreSupabase.from('user_assignments').insert({ user_id: userId, role_id: roleData.id });
          if (assignmentError) throw error;
          responseData = { success: true };
          break;
        }

        case 'assign_vendor_role': {
          const { userId, tenantId } = payload;
          if (!userId || !tenantId) throw new Error('userId and tenantId are required.');
          // vendor_tenants.platform_id es NOT NULL: se deriva del tenant en vez de exigirlo
          // al llamador, para poder usar esta misma acción como asignación manual desde
          // TenantDetails (donde solo se conoce el tenantId).
          const { data: assignTenant, error: assignTenantError } = await coreSupabase
            .from('tenants')
            .select('platform_id')
            .eq('id', tenantId)
            .single();
          if (assignTenantError) throw assignTenantError;
          const { error } = await coreSupabase.from('vendor_tenants').insert({
            user_id: userId,
            tenant_id: tenantId,
            platform_id: assignTenant.platform_id,
          });
          if (error) throw error;
          responseData = { success: true };
          break;
        }

        case 'remove_vendor_tenant_assignment': {
          const { userId, tenantId } = payload;
          if (!userId || !tenantId) throw new Error('userId and tenantId are required.');
          const { error } = await coreSupabase
            .from('vendor_tenants')
            .delete()
            .eq('user_id', userId)
            .eq('tenant_id', tenantId);
          if (error) throw error;
          responseData = { success: true };
          break;
        }

        case 'get_tenant_vendor_assignment': {
          const { tenantId } = payload || {};
          if (!tenantId) throw new Error('tenantId is required.');
          const { data: vtRows, error: vtError } = await coreSupabase
            .from('vendor_tenants')
            .select('user_id')
            .eq('tenant_id', tenantId)
            .order('created_at', { ascending: false })
            .limit(1);
          if (vtError) throw vtError;
          const vtRow = vtRows?.[0];
          if (!vtRow) {
            responseData = null;
            break;
          }
          const { data: vendorUser, error: vendorUserError } = await coreSupabase.auth.admin.getUserById(vtRow.user_id);
          if (vendorUserError) throw vendorUserError;
          responseData = {
            userId: vtRow.user_id,
            email: vendorUser.user.email,
            fullName: `${vendorUser.user.user_metadata?.first_name || ''} ${vendorUser.user.user_metadata?.last_name || ''}`.trim(),
          };
          break;
        }

        case 'assign_vendor_platform_commissions': {
          const { userId, commissions } = payload;
          if (!userId || !commissions) throw new Error('userId and commissions are required.');
          const vendorData = commissions.map((c: any) => ({
            user_id: userId, platform_id: c.platformId, first_payment_commission_rate: c.first_payment_commission_rate / 100, recurring_payment_commission_rate: c.recurring_payment_commission_rate / 100,
          }));
          const { error } = await coreSupabase.from('vendor_platform_commissions').upsert(vendorData, { onConflict: 'user_id, platform_id' });
          if (error) throw error;
          responseData = { success: true };
          break;
        }

        case 'get_platform_trial_plan': {
          const { platformId } = payload || {};
          if (!platformId) throw new Error('platformId is required.');
          const { data: trialPlan, error: trialPlanError } = await coreSupabase
            .from('subscription_plans')
            .select('id, duration_days')
            .eq('platform_id', platformId)
            .eq('is_default_trial', true)
            .maybeSingle();
          if (trialPlanError) throw trialPlanError;
          responseData = trialPlan
            ? { planId: trialPlan.id, durationDays: trialPlan.duration_days }
            : { planId: null, durationDays: null };
          break;
        }

        case 'create_vendor_invitation': {
          const { platformId, vendorUserId, prospect, trialDaysOverride, notes } = payload;
          if (!platformId || !prospect?.firstName) throw new Error('platformId y el nombre del prospecto son requeridos.');

          const isVendorOnly = !callerRoles.includes('super_admin') && !callerRoles.includes('app_super_admin') && !callerRoles.includes('comercial_admin');
          const targetVendorUserId = isVendorOnly ? callerUserId : (vendorUserId || callerUserId);
          if (!targetVendorUserId) throw new Error('No se pudo determinar el vendedor de la invitación.');

          if (trialDaysOverride !== undefined && trialDaysOverride !== null) {
            const { data: trialPlan } = await coreSupabase
              .from('subscription_plans')
              .select('duration_days')
              .eq('platform_id', platformId)
              .eq('is_default_trial', true)
              .maybeSingle();
            if (!trialPlan) {
              throw new Error('Esta plataforma no tiene un plan de prueba configurado; no se pueden asignar días de prueba.');
            }
            // El vendedor solo puede pedir MENOS días que el plan de la plataforma, nunca más.
            if (trialDaysOverride > trialPlan.duration_days) {
              throw new Error(`Los días de prueba no pueden superar los del plan de prueba de la plataforma (${trialPlan.duration_days}).`);
            }
            if (trialDaysOverride < 1) throw new Error('Los días de prueba deben ser al menos 1.');
          }

          const { data: platform, error: platformError } = await coreSupabase
            .from('platforms')
            .select('base_url')
            .eq('id', platformId)
            .single();
          if (platformError) throw platformError;

          const inviteToken = crypto.randomUUID().replace(/-/g, '').slice(0, 8).toUpperCase();
          const base = platform.base_url?.replace(/\/$/, '') || '';
          const inviteUrl = `${base}/registro?ref=${inviteToken}`;

          const { data, error } = await coreSupabase
            .from('vendor_invitations')
            .insert({
              vendor_user_id: targetVendorUserId,
              platform_id: platformId,
              prospect_first_name: prospect.firstName,
              prospect_last_name: prospect.lastName || null,
              prospect_email: prospect.email || null,
              prospect_phone: prospect.phone || null,
              company_name: prospect.companyName || null,
              tax_id: prospect.taxId || null,
              ...extractBusinessFields(prospect),
              invite_token: inviteToken,
              invite_url: inviteUrl,
              trial_days_override: trialDaysOverride ?? null,
              notes: notes || null,
            })
            .select(`*, platform:platforms (name)`)
            .single();
          if (error) throw error;
          responseData = { ...data, platform_name: data.platform.name, platform: undefined };
          break;
        }

        case 'list_vendor_invitations': {
          const { vendorUserId, platformId, status, q } = payload || {};
          const isVendorOnly = !callerRoles.includes('super_admin') && !callerRoles.includes('app_super_admin') && !callerRoles.includes('comercial_admin');

          let query = coreSupabase
            .from('vendor_invitations')
            .select(`*, platform:platforms (name)`);

          if (isVendorOnly) {
            query = query.eq('vendor_user_id', callerUserId);
          } else if (vendorUserId) {
            query = query.eq('vendor_user_id', vendorUserId);
          }
          if (platformId) query = query.eq('platform_id', platformId);
          if (status) query = query.eq('status', status);
          if (q) {
            query = query.or(`prospect_first_name.ilike.%${q}%,prospect_last_name.ilike.%${q}%,prospect_email.ilike.%${q}%,company_name.ilike.%${q}%`);
          }

          const { data, error } = await query.order('created_at', { ascending: false });
          if (error) throw error;
          responseData = (data || []).map((d: any) => ({ ...d, platform_name: d.platform?.name, platform: undefined }));
          break;
        }

        case 'update_vendor_invitation_status': {
          const { invitationId, status, notes } = payload;
          if (!invitationId || !status) throw new Error('invitationId y status son requeridos.');
          const isVendorOnly = !callerRoles.includes('super_admin') && !callerRoles.includes('app_super_admin') && !callerRoles.includes('comercial_admin');

          let query = coreSupabase.from('vendor_invitations').update({
            status,
            ...(notes !== undefined ? { notes } : {}),
          }).eq('id', invitationId);
          if (isVendorOnly) query = query.eq('vendor_user_id', callerUserId);

          const { data, error } = await query.select().single();
          if (error) throw error;
          if (!data) throw new Error('Invitación no encontrada o sin permiso para editarla.');
          responseData = data;
          break;
        }

        case 'delete_vendor_invitation': {
          const { invitationId } = payload;
          if (!invitationId) throw new Error('invitationId es requerido.');
          const isVendorOnly = !callerRoles.includes('super_admin') && !callerRoles.includes('app_super_admin') && !callerRoles.includes('comercial_admin');

          let query = coreSupabase.from('vendor_invitations').delete().eq('id', invitationId);
          if (isVendorOnly) query = query.eq('vendor_user_id', callerUserId);

          const { error } = await query;
          if (error) throw error;
          responseData = { success: true };
          break;
        }

        case 'get_vendor_invitation_funnel': {
          const { vendorUserId, platformId } = payload || {};
          const isVendorOnly = !callerRoles.includes('super_admin') && !callerRoles.includes('app_super_admin') && !callerRoles.includes('comercial_admin');

          let query = coreSupabase.from('vendor_invitations').select('status');
          if (isVendorOnly) {
            query = query.eq('vendor_user_id', callerUserId);
          } else if (vendorUserId) {
            query = query.eq('vendor_user_id', vendorUserId);
          }
          if (platformId) query = query.eq('platform_id', platformId);

          const { data, error } = await query;
          if (error) throw error;
          const counts: Record<string, number> = {};
          for (const row of data || []) {
            counts[row.status] = (counts[row.status] || 0) + 1;
          }
          responseData = counts;
          break;
        }

        case 'get_vendor_conversion_report': {
          const { vendorUserId, platformId } = payload || {};
          const isVendorOnlyCr = !callerRoles.includes('super_admin') && !callerRoles.includes('app_super_admin') && !callerRoles.includes('comercial_admin');

          let prospectsQuery = coreSupabase.from('vendor_prospects').select('vendor_user_id, status');
          let invitationsQuery = coreSupabase.from('vendor_invitations').select('vendor_user_id, status');

          if (isVendorOnlyCr) {
            prospectsQuery = prospectsQuery.eq('vendor_user_id', callerUserId);
            invitationsQuery = invitationsQuery.eq('vendor_user_id', callerUserId);
          } else if (vendorUserId) {
            prospectsQuery = prospectsQuery.eq('vendor_user_id', vendorUserId);
            invitationsQuery = invitationsQuery.eq('vendor_user_id', vendorUserId);
          }
          if (platformId) {
            prospectsQuery = prospectsQuery.eq('platform_id', platformId);
            invitationsQuery = invitationsQuery.eq('platform_id', platformId);
          }

          const [{ data: prospectRows, error: prospectsErr }, { data: invitationRows, error: invitationsErr }] = await Promise.all([prospectsQuery, invitationsQuery]);
          if (prospectsErr) throw prospectsErr;
          if (invitationsErr) throw invitationsErr;

          const stats: Record<string, any> = {};
          const ensureStat = (vid: string) => (stats[vid] ||= {
            vendorUserId: vid,
            prospectsTotal: 0,
            prospectsConverted: 0,
            invitationsTotal: 0,
            invitationsAccountCreated: 0,
            invitationsActive: 0,
            invitationsPaying: 0,
            invitationsLostOrDuplicate: 0,
          });

          for (const p of prospectRows || []) {
            const s = ensureStat(p.vendor_user_id);
            s.prospectsTotal++;
            if (p.status === 'convertido') s.prospectsConverted++;
          }
          for (const inv of invitationRows || []) {
            const s = ensureStat(inv.vendor_user_id);
            s.invitationsTotal++;
            if (['cuenta_creada', 'activo', 'activo_con_plan'].includes(inv.status)) s.invitationsAccountCreated++;
            if (inv.status === 'activo' || inv.status === 'activo_con_plan') s.invitationsActive++;
            if (inv.status === 'activo_con_plan') s.invitationsPaying++;
            if (inv.status === 'perdido' || inv.status === 'duplicado') s.invitationsLostOrDuplicate++;
          }

          responseData = Object.values(stats);
          break;
        }

        case 'invite_superadmin_team_member': {
          const { email, fullName, platforms } = payload;
          if (!email || !fullName || !platforms?.length) {
            throw new Error('email, fullName y al menos una plataforma son requeridos.');
          }

          const nameParts = fullName.trim().split(' ');
          const firstName = nameParts.shift() || '';
          const lastName = nameParts.join(' ');

          // Sin contraseña: el invitado la crea él mismo desde el link (igual patrón que
          // Fel.Api.Tenant/TenantDevelopersController en Facil Factura).
          const { data: newUser, error: createError } = await coreSupabase.auth.admin.createUser({
            email,
            email_confirm: false,
            user_metadata: { full_name: fullName, first_name: firstName, last_name: lastName },
            app_metadata: { assignments: [{ role: 'vendor' }] },
          });
          if (createError) throw createError;

          const commissionRows = platforms.map((p: any) => ({
            user_id: newUser.user.id,
            platform_id: p.platformId,
            first_payment_commission_rate: (p.firstPaymentCommissionRate ?? 50) / 100,
            recurring_payment_commission_rate: (p.recurringPaymentCommissionRate ?? 10) / 100,
          }));
          const { error: commissionError } = await coreSupabase.from('vendor_platform_commissions').insert(commissionRows);
          if (commissionError) throw commissionError;

          const { data: linkData, error: linkError } = await coreSupabase.auth.admin.generateLink({
            type: 'invite',
            email,
            options: { redirectTo: 'https://admin.facil-apps.online/invitacion' },
          });
          if (linkError) throw linkError;
          const actionLink = linkData?.properties?.action_link;
          if (!actionLink) throw new Error('No se pudo generar el link de invitación.');

          // Invitación genérica de Facil Apps Online: platform_id NULL a propósito, no
          // referencia ningún producto/plataforma.
          const { error: queueError } = await coreSupabase.rpc('queue_platform_email', {
            p_platform_id: null,
            p_recipient_email: email,
            p_template_type: 'team_invitation',
            p_template_data: { reset_link: actionLink, user_name: fullName },
            p_tenant_id: null,
          });
          if (queueError) throw queueError;

          responseData = { success: true, userId: newUser.user.id };
          break;
        }

        case 'create_vendor_prospect': {
          const { platformId, vendorUserId, prospect } = payload;
          if (!platformId || !prospect?.firstName) throw new Error('platformId y el nombre del prospecto son requeridos.');

          const isVendorOnlyCp = !callerRoles.includes('super_admin') && !callerRoles.includes('app_super_admin') && !callerRoles.includes('comercial_admin');
          const targetVendorUserId = isVendorOnlyCp ? callerUserId : (vendorUserId || callerUserId);
          if (!targetVendorUserId) throw new Error('No se pudo determinar el vendedor del prospecto.');

          const { data, error } = await coreSupabase
            .from('vendor_prospects')
            .insert({
              vendor_user_id: targetVendorUserId,
              platform_id: platformId,
              first_name: prospect.firstName,
              last_name: prospect.lastName || null,
              phone: prospect.phone || null,
              email: prospect.email || null,
              company_name: prospect.companyName || null,
              tax_id: prospect.taxId || null,
              ...extractBusinessFields(prospect),
            })
            .select(`*, platform:platforms (name)`)
            .single();
          if (error) throw error;
          responseData = { ...data, platform_name: data.platform.name, platform: undefined };
          break;
        }

        case 'list_vendor_prospects': {
          const { vendorUserId, platformId, status, q, dueOnly } = payload || {};
          const isVendorOnlyLp = !callerRoles.includes('super_admin') && !callerRoles.includes('app_super_admin') && !callerRoles.includes('comercial_admin');

          let query = coreSupabase
            .from('vendor_prospects')
            .select(`*, platform:platforms (name)`);

          if (isVendorOnlyLp) {
            query = query.eq('vendor_user_id', callerUserId);
          } else if (vendorUserId) {
            query = query.eq('vendor_user_id', vendorUserId);
          }
          if (platformId) query = query.eq('platform_id', platformId);
          if (status) query = query.eq('status', status);
          if (q) {
            query = query.or(`first_name.ilike.%${q}%,last_name.ilike.%${q}%,email.ilike.%${q}%,company_name.ilike.%${q}%`);
          }
          if (dueOnly) {
            query = query.not('next_visit_at', 'is', null).lte('next_visit_at', new Date().toISOString());
          }

          const { data, error } = await query.order(dueOnly ? 'next_visit_at' : 'created_at', { ascending: !!dueOnly });
          if (error) throw error;
          responseData = (data || []).map((d: any) => ({ ...d, platform_name: d.platform?.name, platform: undefined }));
          break;
        }

        case 'update_vendor_prospect': {
          const { prospectId, prospect } = payload;
          if (!prospectId || !prospect) throw new Error('prospectId y prospect son requeridos.');
          const isVendorOnlyUp = !callerRoles.includes('super_admin') && !callerRoles.includes('app_super_admin') && !callerRoles.includes('comercial_admin');

          const updates: Record<string, unknown> = { ...extractBusinessFields(prospect) };
          if (prospect.firstName !== undefined) updates.first_name = prospect.firstName;
          if (prospect.lastName !== undefined) updates.last_name = prospect.lastName || null;
          if (prospect.phone !== undefined) updates.phone = prospect.phone || null;
          if (prospect.email !== undefined) updates.email = prospect.email || null;
          if (prospect.companyName !== undefined) updates.company_name = prospect.companyName || null;
          if (prospect.taxId !== undefined) updates.tax_id = prospect.taxId || null;

          let query = coreSupabase.from('vendor_prospects').update(updates).eq('id', prospectId);
          if (isVendorOnlyUp) query = query.eq('vendor_user_id', callerUserId);

          const { data, error } = await query.select(`*, platform:platforms (name)`).single();
          if (error) throw error;
          if (!data) throw new Error('Prospecto no encontrado o sin permiso para editarlo.');
          responseData = { ...data, platform_name: data.platform.name, platform: undefined };
          break;
        }

        case 'delete_vendor_prospect': {
          const { prospectId } = payload;
          if (!prospectId) throw new Error('prospectId es requerido.');
          const isVendorOnlyDp = !callerRoles.includes('super_admin') && !callerRoles.includes('app_super_admin') && !callerRoles.includes('comercial_admin');

          let query = coreSupabase.from('vendor_prospects').delete().eq('id', prospectId);
          if (isVendorOnlyDp) query = query.eq('vendor_user_id', callerUserId);

          const { error } = await query;
          if (error) throw error;
          responseData = { success: true };
          break;
        }

        case 'log_vendor_prospect_visit': {
          const { prospectId, status, notes, visitDate, nextVisitDate } = payload;
          if (!prospectId || !status) throw new Error('prospectId y status son requeridos.');
          const isVendorOnlyLv = !callerRoles.includes('super_admin') && !callerRoles.includes('app_super_admin') && !callerRoles.includes('comercial_admin');

          let prospectQuery = coreSupabase.from('vendor_prospects').select('id, vendor_user_id').eq('id', prospectId);
          if (isVendorOnlyLv) prospectQuery = prospectQuery.eq('vendor_user_id', callerUserId);
          const { data: prospectRow, error: prospectError } = await prospectQuery.maybeSingle();
          if (prospectError) throw prospectError;
          if (!prospectRow) throw new Error('Prospecto no encontrado o sin permiso para editarlo.');

          const { data: visit, error: visitError } = await coreSupabase
            .from('vendor_prospect_visits')
            .insert({
              prospect_id: prospectId,
              vendor_user_id: callerUserId || prospectRow.vendor_user_id,
              status,
              notes: notes || null,
              ...(visitDate ? { visit_date: visitDate } : {}),
            })
            .select()
            .single();
          if (visitError) throw visitError;

          const { error: updateProspectError } = await coreSupabase
            .from('vendor_prospects')
            .update({
              status,
              last_visit_at: visit.visit_date,
              // Solo se toca si esta visita trae una fecha nueva; si no, se deja la que ya
              // hubiera (o null si nunca se agendó ninguna).
              ...(nextVisitDate !== undefined ? { next_visit_at: nextVisitDate || null } : {}),
            })
            .eq('id', prospectId);
          if (updateProspectError) throw updateProspectError;

          responseData = visit;
          break;
        }

        case 'list_vendor_prospect_visits': {
          const { prospectId } = payload || {};
          if (!prospectId) throw new Error('prospectId es requerido.');
          const { data, error } = await coreSupabase
            .from('vendor_prospect_visits')
            .select('*')
            .eq('prospect_id', prospectId)
            .order('visit_date', { ascending: false });
          if (error) throw error;
          responseData = data || [];
          break;
        }

        case 'convert_vendor_prospect_to_invitation': {
          const { prospectId, trialDaysOverride } = payload;
          if (!prospectId) throw new Error('prospectId es requerido.');
          const isVendorOnlyCv = !callerRoles.includes('super_admin') && !callerRoles.includes('app_super_admin') && !callerRoles.includes('comercial_admin');

          let prospectQuery = coreSupabase.from('vendor_prospects').select('*').eq('id', prospectId);
          if (isVendorOnlyCv) prospectQuery = prospectQuery.eq('vendor_user_id', callerUserId);
          const { data: prospectRow, error: prospectError } = await prospectQuery.maybeSingle();
          if (prospectError) throw prospectError;
          if (!prospectRow) throw new Error('Prospecto no encontrado o sin permiso para convertirlo.');
          if (prospectRow.status === 'convertido') throw new Error('Este prospecto ya fue convertido a invitación.');

          if (trialDaysOverride !== undefined && trialDaysOverride !== null) {
            const { data: trialPlan } = await coreSupabase
              .from('subscription_plans')
              .select('duration_days')
              .eq('platform_id', prospectRow.platform_id)
              .eq('is_default_trial', true)
              .maybeSingle();
            if (!trialPlan) {
              throw new Error('Esta plataforma no tiene un plan de prueba configurado; no se pueden asignar días de prueba.');
            }
            if (trialDaysOverride > trialPlan.duration_days) {
              throw new Error(`Los días de prueba no pueden superar los del plan de prueba de la plataforma (${trialPlan.duration_days}).`);
            }
            if (trialDaysOverride < 1) throw new Error('Los días de prueba deben ser al menos 1.');
          }

          const { data: platform, error: platformError } = await coreSupabase
            .from('platforms')
            .select('base_url')
            .eq('id', prospectRow.platform_id)
            .single();
          if (platformError) throw platformError;

          const inviteToken = crypto.randomUUID().replace(/-/g, '').slice(0, 8).toUpperCase();
          const base = platform.base_url?.replace(/\/$/, '') || '';
          const inviteUrl = `${base}/registro?ref=${inviteToken}`;

          const { data: invitation, error: invitationError } = await coreSupabase
            .from('vendor_invitations')
            .insert({
              vendor_user_id: prospectRow.vendor_user_id,
              platform_id: prospectRow.platform_id,
              prospect_first_name: prospectRow.first_name,
              prospect_last_name: prospectRow.last_name,
              prospect_email: prospectRow.email,
              prospect_phone: prospectRow.phone,
              company_name: prospectRow.company_name,
              tax_id: prospectRow.tax_id,
              legal_name: prospectRow.legal_name,
              whatsapp_phone: prospectRow.whatsapp_phone,
              billing_address: prospectRow.billing_address,
              einvoicing_email: prospectRow.einvoicing_email,
              physical_address_line1: prospectRow.physical_address_line1,
              physical_address_line2: prospectRow.physical_address_line2,
              physical_city: prospectRow.physical_city,
              physical_state: prospectRow.physical_state,
              physical_postal_code: prospectRow.physical_postal_code,
              website: prospectRow.website,
              latitude: prospectRow.latitude,
              longitude: prospectRow.longitude,
              invite_token: inviteToken,
              invite_url: inviteUrl,
              trial_days_override: trialDaysOverride ?? null,
            })
            .select(`*, platform:platforms (name)`)
            .single();
          if (invitationError) throw invitationError;

          const { error: updateProspectError2 } = await coreSupabase
            .from('vendor_prospects')
            .update({ status: 'convertido', invitation_id: invitation.id })
            .eq('id', prospectId);
          if (updateProspectError2) throw updateProspectError2;

          responseData = { ...invitation, platform_name: invitation.platform.name, platform: undefined };
          break;
        }

        case 'delete_user': {
          const { userId } = payload;
          if (!userId) throw new Error('userId is required for deletion.');
          const { error } = await coreSupabase.auth.admin.deleteUser(userId);
          if (error) throw error;
          responseData = { success: true };
          break;
        }

        case 'update_user_name': {
          const { userId, firstName, lastName } = payload;
          if (!userId || !firstName || !lastName) throw new Error('userId, firstName, and lastName are required.');
          const { error } = await coreSupabase.rpc('update_user_name', {
            user_id_to_update: userId, new_first_name: firstName, new_last_name: lastName,
          });
          if (error) throw error;
          responseData = { success: true };
          break;
        }

        case 'get_vendor_platform_commissions': {
          const { userId } = payload;
          if (!userId) throw new Error('userId is required.');
          const { data, error } = await coreSupabase
            .from('vendor_platform_commissions')
            .select(`*, platform:platforms (name)`)
            .eq('user_id', userId);
          if (error) error; // Changed to throw error directly
          const remappedData = data.map(d => ({ ...d, platform_name: d.platform.name, platform: undefined, }));
          responseData = remappedData;
          break;
        }

        case 'update_vendor_platform_commission': {
          const { commissionId, updates } = payload;
          if (!commissionId || !updates) throw new Error('commissionId and updates are required.');
          const { data, error } = await coreSupabase.from('vendor_platform_commissions').update(updates).eq('id', commissionId).select().single();
          if (error) throw error;
          responseData = data;
          break;
        }

        case 'remove_vendor_platform_commission': {
          const { commissionId } = payload;
          if (!commissionId) throw new Error('commissionId is required.');
          const { error } = await coreSupabase.from('vendor_platform_commissions').delete().eq('id', commissionId);
          if (error) throw error;
          responseData = { success: true };
          break;
        }

        case 'get_platform_financial_stats': {
          const { platformId } = payload || {};
          const { data, error } = await coreSupabase.rpc('get_platform_financial_stats', { p_platform_id: platformId });
          if (error) throw error;
          responseData = data;
          break;
        }

        case 'get_superadmin_payment_stats': {
          const { data, error } = await coreSupabase.rpc('get_superadmin_payment_stats');
          if (error) throw error;
          responseData = data;
          break;
        }

        case 'get_superadmin_payment_stats': {
          const { data, error } = await coreSupabase.rpc('get_superadmin_payment_stats');
          if (error) throw error;
          responseData = data;
          break;
        }

        case 'get_platforms_stats': {
          const { data, error } = await coreSupabase.rpc('get_platforms_stats');
          if (error) throw error;
          responseData = data;
          break;
        }

        case 'get_api_health_stats': {
          const { data, error } = await coreSupabase.rpc('get_api_health_stats'); // Consultar tabla Core nativa
          if (error) throw error;
          responseData = data;
          break;
        }

        case 'get_infrastructure_metrics': {
          const { data: nodes, error: nodesError } = await coreSupabase.from('infrastructure_nodes').select('*').eq('is_active', true);
          if (nodesError) throw nodesError;

          const { createClient } = await import('https://esm.sh/@supabase/supabase-js@2');
          const results = [];

          for (const node of nodes) {
            try {
              const cleanKey = node.service_role_key.replace(/\s+/g, '');
              const nodeClient = createClient(node.project_url, cleanKey, {
                auth: { autoRefreshToken: false, persistSession: false }
              });
              
              const start = Date.now();
              const { error: pingError } = await nodeClient.rpc('non_existent_ping_function');
              const latency = Date.now() - start;

              let status = 'online';
              let details = 'OK';

              if (pingError) {
                // Si el error es PGRST202, significa que la base de datos respondió correctamente
                // indicando que la función no existe. Por lo tanto, el servidor está VIVO.
                if (pingError.code === 'PGRST202') {
                  status = 'online';
                  details = 'OK';
                } else if (pingError.message && pingError.message.includes('Unexpected token')) {
                  status = 'error';
                  details = 'Proyecto pausado o API Key corrupta (Revisar infrastructure_nodes)';
                } else {
                  status = 'warning';
                  details = pingError.message;
                }
              }

              results.push({
                node_id: node.id,
                node_name: node.node_name,
                project_url: node.project_url,
                status: status,
                latency_ms: latency,
                details: details
              });
            } catch (err) {
              results.push({
                node_id: node.id,
                node_name: node.node_name,
                status: 'error',
                details: err.message
              });
            }
          }

          responseData = results;
          break;
        }

        case 'get_investor_dashboard_data': {
          const { platformData } = payload;
          if (!platformData || !Array.isArray(platformData) || platformData.length === 0) throw new Error('platformData is required and must be a non-empty array.');
          const platformIds = platformData.map((p: any) => p.platform_id);
          const { data: platformNames, error: platformNamesError } = await coreSupabase.from('platforms').select('id, name').in('id', platformIds); // Core DB
          if (platformNamesError) throw platformNamesError;
          const platformNameMap = new Map(platformNames.map((p: any) => [p.id, p.name]));
          const now = new Date();
          const currentMonthStart = new Date(now.getFullYear(), now.getMonth(), 1);
          const currentMonthEnd = new Date(now.getFullYear(), now.getMonth() + 1, 0, 23, 59, 59, 999);
          const prevMonthStart = new Date(now.getFullYear(), now.getMonth() - 1, 1);
          const prevMonthEnd = new Date(now.getFullYear(), now.getMonth(), 0, 23, 59, 59, 999);
          
          // Updated to query 'transactions' table
          const { data: payments, error: paymentsError } = await coreSupabase
            .from('transactions')
            .select(`
              amount_in_cents, created_at, status,
              tenant:tenants!transactions_tenant_id_fkey(platform_id, is_system_owner)
            `)
            .in('status', ['APPROVED', 'COMPLETED']) // Accept both statuses
            .eq('environment', 'production')
            .gte('created_at', prevMonthStart.toISOString())
            .lte('created_at', currentMonthEnd.toISOString());

          if (paymentsError) throw paymentsError;

          let currentMonthSales = 0; let previousMonthSales = 0; let currentMonthCommission = 0; let previousMonthCommission = 0;
          const stakeMap = new Map(platformData.map((p: any) => [p.platform_id, p.stake_percentage]));
          
          payments.forEach((payment: any) => {
            const platformId = payment.tenant?.platform_id;
            const isSystemOwner = payment.tenant?.is_system_owner;
            if (!platformId || !stakeMap.has(platformId)) return; // Filter by requested platforms

            const paymentDate = new Date(payment.created_at); // Use created_at
            const amount = payment.amount_in_cents / 100;
            if (isSystemOwner) return;
            
            const stakePercentage = stakeMap.get(platformId) || 0;
            const commission = amount * (stakePercentage / 100);
            
            if (paymentDate >= currentMonthStart && paymentDate <= currentMonthEnd) {
              currentMonthSales += amount; currentMonthCommission += commission;
            } else if (paymentDate >= prevMonthStart && paymentDate <= prevMonthEnd) {
              previousMonthSales += amount; previousMonthCommission += commission;
            }
          });
          responseData = {
            currentMonthSales, previousMonthSales, currentMonthCommission, previousMonthCommission,
            platforms: platformData.map((p: any) => ({
              id: p.platform_id, name: platformNameMap.get(p.platform_id) || 'Unknown Platform', stake_percentage: p.stake_percentage,
            })),
          };
          break;
        }

        case 'insert_system_alert': {
          const { platform_id, type, message, details } = payload;
          if (!platform_id || !type || !message) throw new Error('Platform ID, type, and message are required for inserting a system alert.');
          const { data, error } = await coreSupabase.from('system_alerts').insert({ platform_id, type, message, details }).select().single(); // Core DB
          if (error) throw error;
          responseData = data;
          break;
        }

        case 'get_system_alerts': {
          const { platform_id, type, is_resolved } = payload;
          let query = coreSupabase.from('system_alerts').select('*, platforms(name)').order('created_at', { ascending: false }); // Core DB
          if (platform_id) query = query.eq('platform_id', platform_id);
          if (type) query = query.eq('type', type);
          if (is_resolved !== undefined) query = query.eq('is_resolved', is_resolved);
          const { data, error } = await query;
          if (error) throw error;
          responseData = data.map((alert: any) => ({
            ...alert, platform_name: alert.platforms?.name || 'N/A', platforms: undefined,
          }));
          break;
        }

        case 'update_system_alert_status': {
          const { id, is_resolved, resolved_by } = payload;
          if (!id || is_resolved === undefined || !resolved_by) throw new Error('ID, is_resolved status, and resolved_by are required to update system alert status.');
          const { data, error } = await coreSupabase.from('system_alerts').update({ is_resolved, resolved_at: new Date().toISOString(), resolved_by }).eq('id', id).select().single(); // Core DB
          if (error) throw error;
          responseData = data;
          break;
        }

        // --- Billing Entity Actions ---
        case 'get_billing_entity': {
          const { data, error } = await coreSupabase
            .from('billing_entities')
            .select('*')
            .limit(1)
            .single();
          
          if (error && error.code !== 'PGRST116') { // PGRST116 = 0 rows, not an error
            throw error;
          }
          responseData = data;
          break;
        }

        case 'upsert_billing_entity': {
          const { entityData } = payload;
          if (!entityData) throw new Error('entityData is required.');

          const { data, error } = await coreSupabase
            .from('billing_entities')
            .upsert({ ...entityData, updated_at: new Date().toISOString() }) // Explicitly set updated_at
            .select()
            .single();
          
          if (error) throw error;
          responseData = data;
          break;
        }

        // --- Tenant-facing Subscription Actions ---
        case 'get_subscription_status': {
          const { tenantId, platformId } = payload;
          if (!tenantId) throw new Error('tenantId is required.');
          if (!platformId) throw new Error('platformId is required.');
          const { data, error } = await coreSupabase.rpc('get_tenant_plan_limits', { p_tenant_id: tenantId, p_platform_id: platformId });
          if (error) throw error;
          responseData = Array.isArray(data) ? data[0] || null : data;
          break;
        }

        case 'get_tenant_subscription_plans': {
          const { tenantId: tId, platformId: pId } = payload;
          if (!tId) throw new Error('tenantId is required.');
          if (!pId) throw new Error('platformId is required.');
          const { data: plansData, error: plansError } = await coreSupabase.rpc('get_subscription_plans_for_tenant', { p_tenant_id: tId, p_platform_id: pId });
          if (plansError) throw plansError;
          responseData = plansData || [];
          break;
        }

        case 'get_subscription_usage': {
          const { tenantId: usageTenantId, platformId: usagePlatformId } = payload;
          if (!usageTenantId) throw new Error('tenantId is required.');
          if (!usagePlatformId) throw new Error('platformId is required.');
          
          const { data: limitsData, error: limitsError } = await coreSupabase.rpc('get_tenant_plan_limits', { p_tenant_id: usageTenantId, p_platform_id: usagePlatformId });
          if (limitsError) throw limitsError;
          const limits = Array.isArray(limitsData) ? limitsData[0] : limitsData;
          
          if (!limits || limits.status === 'cancelado') {
            responseData = null;
            break;
          }

          const { data: activeSub } = await coreSupabase
            .from('tenant_subscriptions')
            .select('plan_country_configuration_id')
            .eq('tenant_id', usageTenantId)
            .eq('is_active', true)
            .order('start_date', { ascending: false })
            .limit(1)
            .single();

          const pccId = activeSub?.plan_country_configuration_id;

          const { data: planAssets } = await coreSupabase
            .from('plan_assets')
            .select('*, asset_purposes(purpose_key)')
            .eq('platform_id', usagePlatformId);

          const usage = [];
          for (const asset of planAssets || []) {
            let limitValue = -1;
            if (pccId) {
              const { data: limitData } = await coreSupabase
                .from('plan_asset_limits')
                .select('value')
                .eq('plan_country_config_id', pccId)
                .eq('asset_id', asset.id)
                .maybeSingle();
              if (limitData?.value != null) limitValue = Number(limitData.value);
            }

            let totalUsed = 0;
            if (limits.starts_at && limits.ends_at) {
              const { data: usageData } = await coreSupabase
                .from('asset_usage_tracking')
                .select('quantity_used')
                .eq('tenant_id', usageTenantId)
                .eq('asset_id', asset.id)
                .gte('usage_period_start', limits.starts_at)
                .lte('usage_period_end', limits.ends_at);
              totalUsed = (usageData || []).reduce((sum, u) => sum + (Number(u.quantity_used) || 0), 0);
            }

            usage.push({
              asset_name: asset.name,
              asset_key: asset.asset_key,
              asset_description: asset.description || '',
              asset_purpose_key: asset.asset_purposes?.purpose_key,
              used: totalUsed,
              limit: limitValue,
            });
          }

          responseData = {
            plan_name: limits.plan_name,
            billing_period_start: limits.starts_at,
            billing_period_end: limits.ends_at,
            usage,
          };
          break;
        }

        case 'activate_subscription': {
          const { tenantId: actTenantId, planId } = payload;
          if (!actTenantId || !planId) throw new Error('tenantId and planId are required.');
          const { data: actResult, error: actError } = await coreSupabase.rpc('activate_subscription', {
            p_tenant_id: actTenantId,
            p_plan_id: planId,
          });
          if (actError) throw actError;
          responseData = actResult;
          break;
        }

        case 'generate_wompi_checkout': {
          const { tenantId: checkoutTenantId, redirectUrl, userId, planId, currency, extraItems } = payload;
          if (!checkoutTenantId || !redirectUrl || !userId || !planId) {
            throw new Error('tenantId, redirectUrl, userId, and planId are required.');
          }

          const wompiUrl = `${Deno.env.get('SUPABASE_URL')}/functions/v1/wompi-generate-checkout`;
          const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || Deno.env.get('SUPABASE_ANON_KEY');
          const wompiResponse = await fetch(wompiUrl, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${serviceKey}` },
            body: JSON.stringify({
              tenantId: checkoutTenantId, redirectUrl, userId, planId,
              currency: currency || 'COP', extraItems: extraItems || [],
            }),
          });

          if (!wompiResponse.ok) {
            const errorBody = await wompiResponse.text();
            console.error(`[core-actions] wompi-generate-checkout returned ${wompiResponse.status}:`, errorBody);
            throw new Error(`wompi-generate-checkout failed (${wompiResponse.status}): ${errorBody}`);
          }

          const checkoutResult = await wompiResponse.json();
          responseData = checkoutResult;
          break;
        }

        default:
          console.log(`[core-actions] Action '${action}' did not match any case.`);
          statusCode = 400;
          throw new Error(`Invalid action: ${action}`);
      }
    } catch (error) {
      statusCode = error.code?.startsWith('PGRST') ? 400 : 500;
      console.error(`Error in action '${action}':`, error.message);
      responseData = { success: false, message: error.message };
    } finally {
      const endTime = performance.now();
      const responseTimeMs = endTime - startTime;
      console.log(`core-actions: Action '${action}' took ${responseTimeMs.toFixed(2)}ms, status: ${statusCode}`);
      await coreSupabase.from('api_request_metrics').insert({ // Changed to coreSupabase
        path: metricsPath, method: 'POST', status_code: statusCode, response_time_ms: responseTimeMs
      });
    }

    return new Response(JSON.stringify(responseData), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: statusCode,
    });

  } catch (error) {
    return new Response(JSON.stringify({
      success: false, message: error.message,
    }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 400,
    });
  }
});
