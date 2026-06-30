import { serve } from 'https://deno.land/std@0.177.0/http/server.ts'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const { refresh_token } = await req.json()

    if (!refresh_token) {
      throw new Error('El "refresh_token" es requerido.')
    }

    const revokeUrl = `https://oauth2.googleapis.com/revoke?token=${refresh_token}`;

    const response = await fetch(revokeUrl, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded'
      }
    });

    if (!response.ok) {
      const errorData = await response.json();
      throw new Error(`Error al revocar el token: ${errorData.error_description || response.statusText}`);
    }

    return new Response(
      JSON.stringify({ success: true, message: 'Token revocado exitosamente.' }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )
  } catch (error) {
    return new Response(JSON.stringify({ success: false, error: error.message }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 400,
    })
  }
})
