
import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { encode } from "https://deno.land/std@0.208.0/encoding/base64.ts";
import { getTenantSupabaseClient, getCoreSupabaseClient } from '../_shared/supabaseClients.ts';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

console.log("Initializing public-actions function (distributed architecture)");

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const { action, payload } = await req.json();
    console.log(`public-actions: Received action '${action}'`);

    const coreSupabase = getCoreSupabaseClient();
    const tenantSupabase = getTenantSupabaseClient();

    let responseData: any;
    let statusCode = 200;

    try {
      switch (action) {
        // --- CORE DATABASE ACTIONS ---
        case 'GET_PUBLIC_SUBSCRIPTION_PLANS': {
          const { countryId, platformId } = payload;
          if (!countryId || !platformId) {
            throw new Error('countryId and platformId are required.');
          }

          const { data, error } = await coreSupabase.rpc('get_public_subscription_plans', {
            p_country_id: countryId,
            p_platform_id: platformId,
          });

          if (error) throw error;
          responseData = data;
          break;
        }
        
        case 'get-currencies': {
          const { data, error } = await coreSupabase.from('currencies').select('*').order('name');
          if (error) throw error;
          responseData = data;
          break;
        }

        case 'get-countries': {
          const { data, error } = await coreSupabase.from('countries').select('*, currencies(code, symbol)').order('name', { ascending: true });
          if (error) throw error;
          responseData = data;
          break;
        }

        // --- TENANT DATABASE ACTIONS ---
        case 'UPDATE_TV_PLAYBACK_STATE': {
          const { branch_id, current_playlist_item_id, video_started_at } = payload;
          if (!branch_id || !current_playlist_item_id || !video_started_at) {
            throw new Error('branch_id, current_playlist_item_id, and video_started_at are required for UPDATE_TV_PLAYBACK_STATE.');
          }
          const { data, error } = await tenantSupabase
            .from('branch_playback_state')
            .upsert({
              branch_id: branch_id,
              current_playlist_item_id: current_playlist_item_id,
              video_started_at: video_started_at,
            }, { onConflict: 'branch_id' })
            .select()
            .single();
          if (error) throw error;
          responseData = data;
          break;
        }

        case 'public_get_or_create_tv_display': {
          const { p_id, p_registration_code } = payload;
          const { data, error } = await tenantSupabase.rpc('get_or_create_tv_display', { 
            p_id: p_id, 
            p_registration_code: p_registration_code 
          });
          if (error) throw error;
          responseData = (data && data.length > 0) ? data[0] : null;
          break;
        }
        
        case 'public_get_current_turns': {
          const { p_branch_id } = payload;
          if (!p_branch_id) throw new Error('Branch ID is required.');
          const { data, error } = await tenantSupabase.rpc('get_current_turns_for_branch', { p_branch_id });
          if (error) throw error;
          responseData = data;
          break;
        }
        
        case 'public_get_playlist_items': {
          const { p_playlist_id } = payload;
          if (!p_playlist_id) throw new Error('Playlist ID is required.');
          const { data: tv, error: tvError } = await tenantSupabase
            .from('tv_displays')
            .select('id')
            .eq('media_playlist_id', p_playlist_id)
            .eq('is_registered', true)
            .limit(1)
            .single();
          if (tvError && tvError.code !== 'PGRST116') throw tvError;
          if (!tv) throw new Error('Access denied: Playlist is not assigned to a registered TV.');
          const { data, error } = await tenantSupabase
            .from('playlist_items')
            .select('*')
            .eq('playlist_id', p_playlist_id)
            .order('item_order', { ascending: true });
          if (error) throw error;
          responseData = data;
          break;
        }

        case 'get-phone-prefixes': {
          const { data, error } = await tenantSupabase
            .from('phone_prefixes')
            .select('*')
            .order('country_name', { ascending: true });
          if (error) throw error;
          responseData = data;
          break;
        }

        case 'SUBMIT_SURVEY': {
          const { survey_token, ratings } = payload;
          if (!survey_token || !ratings || !Array.isArray(ratings)) throw new Error('Survey token and a ratings array are required.');
          const { data: survey, error: surveyError } = await tenantSupabase.from('satisfaction_surveys').select('id, tenant_id, branch_id, status').eq('survey_token', survey_token).single();
          if (surveyError) throw new Error(`Error fetching survey: ${surveyError.message}`);
          if (!survey) throw new Error('Survey not found or invalid token.');
          if (survey.status === 'completed') throw new Error('This survey has already been completed.');
          const ratingRecords = ratings.map(r => ({ survey_id: survey.id, attention_service_id: r.attention_service_id, rating: r.rating, comments: r.comments, tenant_id: survey.tenant_id, branch_id: survey.branch_id }));
          const { error: insertRatingsError } = await tenantSupabase.from('satisfaction_survey_ratings').insert(ratingRecords);
          if (insertRatingsError) throw new Error(`Error saving ratings: ${insertRatingsError.message}`);
          const { error: updateSurveyError } = await tenantSupabase.from('satisfaction_surveys').update({ status: 'completed', submitted_at: new Date().toISOString() }).eq('id', survey.id);
          if (updateSurveyError) console.error(`CRITICAL: Failed to mark survey ${survey.id} as completed after saving ratings. Error: ${updateSurveyError.message}`);
          responseData = { success: true, message: 'Thank you for your feedback!' };
          break;
        }

        case 'get_microsite_data': {
          const { country_iso_code, slug, platform_id } = payload;
          if (!country_iso_code || !slug || !platform_id) throw new Error('Country ISO code, slug, and platform ID are required.');

          // 1. Fetch tenant data from the CORE database using the new RPC
          const { data: tenantData, error: tenantError } = await coreSupabase.rpc('get_tenant_for_microsite', {
            p_country_iso_code: country_iso_code,
            p_slug: slug,
            p_platform_id: platform_id,
          });

          if (tenantError) {
            console.error(`Error invoking get_tenant_for_microsite RPC: ${tenantError.message}`);
            throw new Error(`Error fetching tenant: ${tenantError.message}`);
          }
          
          if (!tenantData) {
            statusCode = 404;
            throw new Error('Microsite not found.');
          }

          // Create a mutable copy to avoid "Assignment to constant variable" error.
          let finalTenantData = { ...tenantData };

          // 2. Fetch social networks for that tenant from the TENANT database
          const { data: socialNetworks, error: socialNetworksError } = await tenantSupabase
            .from('tenant_social_networks')
            .select('network, url')
            .eq('tenant_id', finalTenantData.id)
            .eq('platform_id', finalTenantData.platform_id);

          if (socialNetworksError) {
            console.error(`Error fetching social networks for tenant ${finalTenantData.id}:`, socialNetworksError.message);
            // Do not fail the request, just return an empty array for social networks
            finalTenantData.social_networks = [];
          } else {
            finalTenantData.social_networks = socialNetworks || [];
          }

          // 3. Fetch branches for that tenant from the TENANT database using the new RPC
          let branchesData;
          const { data, error: branchesError } = await tenantSupabase.rpc('get_branches_for_microsite', {
            p_tenant_id: finalTenantData.id,
          });

          if (branchesError) {
            console.error(`Error invoking get_branches_for_microsite RPC: ${branchesError.message}`);
            // It's possible the tenant exists but has no branches, so don't throw a hard error.
            // Just return an empty array for branches.
            branchesData = [];
          } else {
            branchesData = data;
          }

          // 4. Combine and return the data
          responseData = {
            tenant: finalTenantData,
            branches: branchesData || [],
          };
          break;
        }

        case 'public_get_tenant_basic_info': {
          const { tenantId } = payload;
          if (!tenantId) throw new Error('Tenant ID is required.');
          const { data, error } = await coreSupabase
            .from('tenants')
            .select('id, logo_url')
            .eq('id', tenantId)
            .single();
          if (error) throw error;
          responseData = data;
          break;
        }
        
        default:
          statusCode = 400;
          throw new Error(`Invalid action for public-actions: ${action}`);
      }
    } catch (error) {
      statusCode = 500;
      console.error(`Error in public action '${action}':`, error.message);
      responseData = { success: false, message: error.message };
    }

    return new Response(JSON.stringify(responseData), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: statusCode,
    });

  } catch (error) {
    return new Response(JSON.stringify({
      success: false,
      message: error.message,
    }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 400,
    });
  }
});
