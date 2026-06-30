import { serve } from 'https://deno.land/std@0.177.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    // 1. Verificar que quien llama es un super_admin
    const authHeader = req.headers.get('Authorization')!
    const client = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      { global: { headers: { Authorization: authHeader } } }
    )
    const { data: { user }, error: userError } = await client.auth.getUser()
    if (userError) throw userError
    
    // Asumimos que el rol está en los metadatos del token personalizado
    if (user.user_metadata?.role !== 'super_admin') {
      return new Response(JSON.stringify({ error: 'No tienes permiso para realizar esta acción.' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 403,
      })
    }

    // 2. Obtener el email del usuario objetivo del cuerpo de la solicitud
    const { userEmail } = await req.json()
    if (!userEmail) {
      return new Response(JSON.stringify({ error: 'Se requiere "userEmail".' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 400,
      })
    }

    // 3. Crear el cliente de ADMIN para generar el enlace
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    )

    // 4. Generar el enlace de reseteo de contraseña para el email objetivo
    const { data, error: linkError } = await supabaseAdmin.auth.admin.generateLink({
      type: 'recovery',
      email: userEmail, // <-- CORRECCIÓN: Usar el email del parámetro
    });
    
    if (linkError) throw linkError

    // 5. Devolver el enlace al frontend
    return new Response(JSON.stringify({ recoveryLink: data.properties.action_link }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200,
    })

  } catch (error) {
    return new Response(JSON.stringify({ error: error.message }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 500,
    })
  }
})
