import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders })
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY')!
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

    // 1. Verify authentication
    const authHeader = req.headers.get('Authorization')
    if (!authHeader?.startsWith('Bearer ')) {
      console.log('No authorization header provided')
      return new Response(
        JSON.stringify({ error: 'Unauthorized - No authorization header' }), 
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    // 2. Validate JWT token using anon client
    const supabaseAuth = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: authHeader } }
    })

    const token = authHeader.replace('Bearer ', '')
    const { data: claimsData, error: claimsError } = await supabaseAuth.auth.getClaims(token)
    
    if (claimsError || !claimsData?.claims) {
      console.log('Invalid token:', claimsError?.message)
      return new Response(
        JSON.stringify({ error: 'Unauthorized - Invalid token' }), 
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const userId = claimsData.claims.sub as string

    // 3. Check if user is super admin (using service role for elevated query)
    const supabaseService = createClient(supabaseUrl, supabaseServiceKey)
    
    const { data: profile, error: profileError } = await supabaseService
      .from('profiles')
      .select('is_super_admin, tenant_id')
      .eq('user_id', userId)
      .single()

    if (profileError || !profile?.is_super_admin) {
      console.log('User is not super admin:', userId)
      return new Response(
        JSON.stringify({ error: 'Forbidden - Admin access required' }), 
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    console.log('Authenticated super admin:', userId)

    // Now proceed with service role client
    const supabase = supabaseService

    // Obtener notificaciones pendientes agrupadas por usuario
    const { data: pendingNotifications, error } = await supabase
      .from('pending_summary_notifications')
      .select('*')
      .eq('processed', false)
      .order('user_id')
      .order('notification_type')

    if (error) throw error

    // Agrupar por usuario
    const userNotificationsMap = new Map<string, typeof pendingNotifications>()
    
    for (const notification of pendingNotifications || []) {
      const existing = userNotificationsMap.get(notification.user_id) || []
      existing.push(notification)
      userNotificationsMap.set(notification.user_id, existing)
    }

    const results = []

    for (const [notifUserId, notifications] of userNotificationsMap) {
      if (notifications.length === 0) continue

      const tenantId = notifications[0].tenant_id

      // Agrupar por tipo para el resumen
      const groupedByType = new Map<string, number>()
      for (const n of notifications) {
        groupedByType.set(n.notification_type, (groupedByType.get(n.notification_type) || 0) + 1)
      }

      // Crear mensaje de resumen
      const summaryParts: string[] = []
      const typeLabels: Record<string, string> = {
        'examen_vencer': 'exámenes por vencer',
        'curso_vencer': 'cursos por vencer',
        'dotacion_vencer': 'dotaciones por vencer',
        'vigilancia_seguimiento': 'vigilancias con seguimiento pendiente',
        'comite_reunion': 'reuniones de comités próximas',
        'evaluacion_pendiente': 'evaluaciones pendientes'
      }

      for (const [type, count] of groupedByType) {
        const label = typeLabels[type] || type
        summaryParts.push(`${count} ${label}`)
      }

      const summaryMessage = `Resumen de alertas: ${summaryParts.join(', ')}.`

      // Crear notificación consolidada
      await supabase
        .from('notifications')
        .insert({
          user_id: notifUserId,
          tenant_id: tenantId,
          type: 'resumen',
          title: `Resumen: ${notifications.length} alertas pendientes`,
          message: summaryMessage,
          link: '/dashboard'
        })

      // Marcar como procesadas
      const notificationIds = notifications.map(n => n.id)
      await supabase
        .from('pending_summary_notifications')
        .update({ processed: true, processed_at: new Date().toISOString() })
        .in('id', notificationIds)

      results.push({
        userId: notifUserId,
        notificationsConsolidated: notifications.length
      })
    }

    console.log('Summary notifications sent successfully:', results.length, 'users processed')

    return new Response(
      JSON.stringify({ success: true, results }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )

  } catch (error) {
    console.error('Error sending summary notifications:', error)
    const errorMessage = error instanceof Error ? error.message : 'Unknown error'
    return new Response(
      JSON.stringify({ error: errorMessage }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )
  }
})
