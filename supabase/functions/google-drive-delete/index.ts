import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { getCoreSupabaseClient } from '../_shared/supabaseClients.ts';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

// Las credenciales de Google Drive (tenant_integrations) viven en Core, no en Services.
// Esta función conserva el contrato histórico { fileId, tenantId, uploadContext? } y delega
// el borrado real en la edge function Core 'google-drive-delete'.
serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const { fileId, tenantId, uploadContext } = await req.json();
    if (!fileId) {
      return new Response(JSON.stringify({ error: 'Missing required body parameters: fileId is required.' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    let platformId: string | undefined;
    if (tenantId) {
      const supabaseAdmin = createClient(
        Deno.env.get('SUPABASE_URL') ?? '',
        Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
      );
      const { data: tenant } = await supabaseAdmin.from('tenants').select('platform_id').eq('id', tenantId).single();
      platformId = tenant?.platform_id;
    }

    const coreSupabase = getCoreSupabaseClient();
    const { data, error } = await coreSupabase.functions.invoke('google-drive-delete', {
      body: {
        fileId,
        platform_id: platformId,
        // Avatars usa la integración del dueño del sistema (Core la resuelve por plataforma).
        ...(uploadContext === 'Avatars' || !tenantId ? {} : { integration_owner_tenant_id: tenantId }),
      },
    });
    if (error) throw new Error(error.message);

    return new Response(JSON.stringify(data ?? { success: true }), {
      status: 200,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  } catch (error) {
    console.error('Error in google-drive-delete (Services proxy):', error);
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});
