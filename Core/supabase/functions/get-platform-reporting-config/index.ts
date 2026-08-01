import { getSupabaseAdminClient } from '../_shared/supabaseClients.ts';
import { corsHeaders } from '../_shared/cors.ts';

/**
 * Resolves the reporting configuration for a platform.
 * Facil Reports (server-to-server) calls this with an API key to know which
 * Supabase project, Drive folder and platform identity correspond to that key.
 *
 * Requires header `X-Service-Secret` matching env FAO_REPORTING_SERVICE_SECRET.
 * POST { "apiKey": "nexu_live_..." }
 * Returns the platform reporting config including the Supabase service key
 * (needed by Facil Reports to call that platform's google-drive-upload function).
 */
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    // Protect the endpoint: only Facil Reports server should call this.
    const expectedSecret = Deno.env.get('FAO_REPORTING_SERVICE_SECRET');
    const providedSecret = req.headers.get('X-Service-Secret');

    if (!expectedSecret || providedSecret !== expectedSecret) {
      return new Response(
        JSON.stringify({ error: 'Unauthorized' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 401 }
      );
    }

    const { apiKey } = await req.json();
    if (!apiKey || typeof apiKey !== 'string') {
      return new Response(
        JSON.stringify({ error: 'apiKey is required' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400 }
      );
    }

    const supabase = getSupabaseAdminClient();

    const { data, error } = await supabase
      .from('platform_reporting_config')
      .select(`
        id,
        platform_id,
        reporting_api_key,
        api_key_prefix,
        supabase_url,
        supabase_service_key,
        drive_folder_id,
        is_active,
        platform:platforms (id, name, slug)
      `)
      .eq('reporting_api_key', apiKey)
      .eq('is_active', true)
      .maybeSingle();

    if (error) {
      throw error;
    }

    if (!data) {
      return new Response(
        JSON.stringify({ valid: false, error: 'Invalid API key' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 200 }
      );
    }

    return new Response(
      JSON.stringify({
        valid: true,
        platformId: data.platform_id,
        platformName: data.platform?.name ?? '',
        platformSlug: data.platform?.slug ?? '',
        apiKeyPrefix: data.api_key_prefix,
        supabaseUrl: data.supabase_url,
        supabaseServiceKey: data.supabase_service_key,
        driveFolderId: data.drive_folder_id,
      }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 200 }
    );
  } catch (err) {
    return new Response(
      JSON.stringify({ error: err instanceof Error ? err.message : 'Internal error' }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 500 }
    );
  }
});
