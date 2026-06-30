import { serve } from 'https://deno.land/std@0.177.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { corsHeaders } from '../_shared/cors.ts'

serve(async (req) => {
  // Manejo de la solicitud pre-vuelo (preflight) de CORS
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    // 1. Creación de un cliente de Supabase para verificar la autenticación del llamador
    const authHeader = req.headers.get('Authorization')!
    const client = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      { global: { headers: { Authorization: authHeader } } }
    )

    // 2. Verificación del rol del usuario que realiza la llamada
    const { data: { user }, error: userError } = await client.auth.getUser()
    if (userError) throw userError
    
    // Solo los super_admin pueden ejecutar esta función
    if (user.user_metadata?.role !== 'super_admin') {
      return new Response(JSON.stringify({ error: 'No tienes permiso para realizar esta acción.' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 403,
      })
    }

    // 3. Obtención de los parámetros del cuerpo de la solicitud
    const { userId, action } = await req.json()
    if (!userId || !action || !['activate', 'deactivate'].includes(action)) {
      return new Response(JSON.stringify({ error: 'Parámetros inválidos. Se requiere "userId" y "action" (\'activate\' o \'deactivate\').' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 400,
      })
    }

    // 4. Creación del cliente de ADMIN para realizar la modificación
    // Este cliente usa la service_role_key y tiene permisos elevados
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    )

    // 5. Lógica para activar/desactivar
    let banned_until
    if (action === 'deactivate') {
      const futureDate = new Date()
      futureDate.setFullYear(futureDate.getFullYear() + 100)
      banned_until = futureDate.toISOString()
    } else { // 'activate'
      banned_until = new Date().toISOString()
    }

    // 6. Actualización del usuario
    const { error: updateError } = await supabaseAdmin.auth.admin.updateUserById(
      userId,
      { banned_until }
    )

    if (updateError) throw updateError

    return new Response(JSON.stringify({ message: `Usuario ${action === 'activate' ? 'activado' : 'desactivado'} correctamente.` }), {
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