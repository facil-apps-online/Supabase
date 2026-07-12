import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { getSupabaseAdminClient } from '../_shared/supabaseClients.ts';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const { action, ...payload } = await req.json();
    const supabaseClient = getSupabaseAdminClient();

    let result;

    switch (action) {
      case 'get_public_registration_data':
        if (!payload.platform_id) {
            throw new Error('platform_id is required');
        }
        const { data: regData, error: regError } = await supabaseClient.rpc('get_public_registration_data', {
            p_platform_id: payload.platform_id
        });
        
        if (regError) throw regError;
        result = regData;
        break;

      case 'get-phone-prefixes':
        const { data: prefixesData, error: prefixesError } = await supabaseClient.rpc('get_public_phone_prefixes');
        if (prefixesError) throw prefixesError;
        result = prefixesData;
        break;

      case 'get_public_platforms':
        const { data: platformsData, error: platformsError } = await supabaseClient
          .from('platforms')
          .select(`
            id,
            name,
            slug,
            status,
            description,
            description_en,
            base_url,
            logo_url,
            social_facebook,
            social_instagram,
            display_order,
            category_id,
            platform_categories:category_id (
              id,
              slug,
              platform_category_translations (
                locale,
                name
              )
            )
          `)
          .eq('is_public', true)
          .order('display_order', { ascending: true })
          .order('name', { ascending: true });

        if (platformsError) throw platformsError;
        result = platformsData;
        break;

      default:
        throw new Error(`Action '${action}' not found`);
    }

    return new Response(JSON.stringify(result), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200,
    });

  } catch (error) {
    return new Response(JSON.stringify({ error: error.message }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 400,
    });
  }
});
