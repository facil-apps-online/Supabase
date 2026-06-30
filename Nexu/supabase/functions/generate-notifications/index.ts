import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

interface AlertConfig {
  enabled: boolean;
  daysBeforeExpiry: number;
  sendEmail: boolean;
}

interface AlertSettings {
  examenesVencer: AlertConfig;
  cursosVencer: AlertConfig;
  dotacionVencer: AlertConfig;
  vigilanciasSeguimiento: AlertConfig;
  comitesReunion: AlertConfig;
  evaluacionesPendientes: AlertConfig;
}

interface UserPreferences {
  receive_summary: boolean;
  summary_frequency: string;
  email_enabled: boolean;
  in_app_enabled: boolean;
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

    // Now proceed with the notification generation using service role
    const supabase = supabaseService

    // Obtener todos los tenants activos
    const { data: tenants, error: tenantsError } = await supabase
      .from('tenants')
      .select('id, name, settings')
      .eq('active', true)

    if (tenantsError) throw tenantsError

    const results = []

    for (const tenant of tenants || []) {
      const tenantId = tenant.id
      const settings = (tenant.settings as any)?.alerts as AlertSettings
      
      if (!settings) continue

      // Obtener empleados activos del tenant
      const { data: employees } = await supabase
        .from('employees')
        .select('id, first_name, last_name, email, tenant_id')
        .eq('tenant_id', tenantId)
        .eq('active', true)

      // Obtener usuarios administradores del tenant
      const { data: adminUsers } = await supabase
        .from('profiles')
        .select('user_id, first_name, last_name, email')
        .eq('tenant_id', tenantId)
        .eq('active', true)

      const today = new Date()
      const notifications: Array<{
        userId: string;
        type: string;
        title: string;
        message: string;
        link?: string;
        entityId?: string;
        isAdmin: boolean;
      }> = []

      // 1. EXÁMENES POR VENCER
      if (settings.examenesVencer?.enabled) {
        const daysLimit = settings.examenesVencer.daysBeforeExpiry || 30
        const limitDate = new Date(today)
        limitDate.setDate(limitDate.getDate() + daysLimit)

        const { data: exams } = await supabase
          .from('exams')
          .select('id, exam_type, expiry_date, employee_id, employees(first_name, last_name)')
          .eq('tenant_id', tenantId)
          .lte('expiry_date', limitDate.toISOString().split('T')[0])
          .gte('expiry_date', today.toISOString().split('T')[0])

        for (const exam of exams || []) {
          const employee = exam.employees as any
          const employeeName = `${employee?.first_name} ${employee?.last_name}`
          
          // Notificación para administradores
          for (const admin of adminUsers || []) {
            notifications.push({
              userId: admin.user_id,
              type: 'examen_vencer',
              title: 'Examen próximo a vencer',
              message: `El examen "${exam.exam_type}" de ${employeeName} vence el ${exam.expiry_date}`,
              link: '/examenes',
              entityId: exam.id,
              isAdmin: true
            })
          }
        }
      }

      // 2. CURSOS POR VENCER
      if (settings.cursosVencer?.enabled) {
        const daysLimit = settings.cursosVencer.daysBeforeExpiry || 30
        const limitDate = new Date(today)
        limitDate.setDate(limitDate.getDate() + daysLimit)

        const { data: courses } = await supabase
          .from('courses')
          .select('id, course_name, expiry_date, employee_id, employees(first_name, last_name)')
          .eq('tenant_id', tenantId)
          .lte('expiry_date', limitDate.toISOString().split('T')[0])
          .gte('expiry_date', today.toISOString().split('T')[0])

        for (const course of courses || []) {
          const employee = course.employees as any
          const employeeName = `${employee?.first_name} ${employee?.last_name}`
          
          for (const admin of adminUsers || []) {
            notifications.push({
              userId: admin.user_id,
              type: 'curso_vencer',
              title: 'Curso próximo a vencer',
              message: `El curso "${course.course_name}" de ${employeeName} vence el ${course.expiry_date}`,
              link: '/cursos',
              entityId: course.id,
              isAdmin: true
            })
          }
        }
      }

      // 3. DOTACIÓN POR VENCER
      if (settings.dotacionVencer?.enabled) {
        const daysLimit = settings.dotacionVencer.daysBeforeExpiry || 30
        const limitDate = new Date(today)
        limitDate.setDate(limitDate.getDate() + daysLimit)

        const { data: dotacion } = await supabase
          .from('dotacion')
          .select('id, item_name, expiry_date, employee_id, employees(first_name, last_name)')
          .eq('tenant_id', tenantId)
          .lte('expiry_date', limitDate.toISOString().split('T')[0])
          .gte('expiry_date', today.toISOString().split('T')[0])

        for (const item of dotacion || []) {
          const employee = item.employees as any
          const employeeName = `${employee?.first_name} ${employee?.last_name}`
          
          for (const admin of adminUsers || []) {
            notifications.push({
              userId: admin.user_id,
              type: 'dotacion_vencer',
              title: 'Dotación próxima a vencer',
              message: `La dotación "${item.item_name}" de ${employeeName} vence el ${item.expiry_date}`,
              link: '/dotacion',
              entityId: item.id,
              isAdmin: true
            })
          }
        }
      }

      // 4. VIGILANCIAS CON SEGUIMIENTO PENDIENTE
      if (settings.vigilanciasSeguimiento?.enabled) {
        const daysLimit = settings.vigilanciasSeguimiento.daysBeforeExpiry || 7
        const limitDate = new Date(today)
        limitDate.setDate(limitDate.getDate() + daysLimit)

        const { data: vigilancias } = await supabase
          .from('vigilancias')
          .select('id, vigilancia_type, follow_up_date, employee_id, employees(first_name, last_name)')
          .eq('tenant_id', tenantId)
          .eq('status', 'activa')
          .lte('follow_up_date', limitDate.toISOString().split('T')[0])
          .gte('follow_up_date', today.toISOString().split('T')[0])

        for (const vig of vigilancias || []) {
          const employee = vig.employees as any
          const employeeName = `${employee?.first_name} ${employee?.last_name}`
          
          for (const admin of adminUsers || []) {
            notifications.push({
              userId: admin.user_id,
              type: 'vigilancia_seguimiento',
              title: 'Seguimiento de vigilancia pendiente',
              message: `Vigilancia "${vig.vigilancia_type}" de ${employeeName} requiere seguimiento el ${vig.follow_up_date}`,
              link: '/vigilancias',
              entityId: vig.id,
              isAdmin: true
            })
          }
        }
      }

      // 5. REUNIONES DE COMITÉS PRÓXIMAS
      if (settings.comitesReunion?.enabled) {
        const daysLimit = settings.comitesReunion.daysBeforeExpiry || 7
        const limitDate = new Date(today)
        limitDate.setDate(limitDate.getDate() + daysLimit)

        const { data: meetings } = await supabase
          .from('committee_meetings')
          .select('id, meeting_date, location, committees(id, name, tenant_id)')
          .gte('meeting_date', today.toISOString())
          .lte('meeting_date', limitDate.toISOString())

        for (const meeting of meetings || []) {
          const committee = meeting.committees as any
          if (committee?.tenant_id !== tenantId) continue
          
          for (const admin of adminUsers || []) {
            notifications.push({
              userId: admin.user_id,
              type: 'comite_reunion',
              title: 'Reunión de comité próxima',
              message: `Reunión del comité "${committee.name}" programada para ${new Date(meeting.meeting_date).toLocaleDateString()}`,
              link: '/comites',
              entityId: meeting.id,
              isAdmin: true
            })
          }
        }
      }

      // 6. EVALUACIONES PENDIENTES
      if (settings.evaluacionesPendientes?.enabled) {
        const { data: evaluations } = await supabase
          .from('performance_evaluations')
          .select('id, period, evaluation_date, employee_id, employees(first_name, last_name)')
          .eq('tenant_id', tenantId)
          .eq('status', 'pendiente')

        for (const evaluation of evaluations || []) {
          const employee = evaluation.employees as any
          const employeeName = `${employee?.first_name} ${employee?.last_name}`
          
          for (const admin of adminUsers || []) {
            notifications.push({
              userId: admin.user_id,
              type: 'evaluacion_pendiente',
              title: 'Evaluación de desempeño pendiente',
              message: `Evaluación de ${employeeName} (${evaluation.period}) pendiente de completar`,
              link: '/evaluaciones-desempeno',
              entityId: evaluation.id,
              isAdmin: true
            })
          }
        }
      }

      // Procesar notificaciones según preferencias de usuario
      const userNotificationsMap = new Map<string, typeof notifications>()
      
      for (const notification of notifications) {
        const existing = userNotificationsMap.get(notification.userId) || []
        existing.push(notification)
        userNotificationsMap.set(notification.userId, existing)
      }

      for (const [notifUserId, userNotifications] of userNotificationsMap) {
        // Obtener preferencias del usuario
        const { data: prefs } = await supabase
          .rpc('get_user_notification_preferences', { _user_id: notifUserId })

        const preferences: UserPreferences = prefs?.[0] || {
          receive_summary: false,
          summary_frequency: 'daily',
          email_enabled: true,
          in_app_enabled: true
        }

        if (!preferences.in_app_enabled) continue

        if (preferences.receive_summary) {
          // Guardar para resumen consolidado
          const summaryNotifications = userNotifications.map(n => ({
            user_id: notifUserId,
            tenant_id: tenantId,
            notification_type: n.type,
            title: n.title,
            message: n.message,
            link: n.link,
            related_entity_id: n.entityId
          }))

          await supabase
            .from('pending_summary_notifications')
            .insert(summaryNotifications)
        } else {
          // Crear notificaciones individuales inmediatamente
          // Evitar duplicados verificando si ya existe una notificación similar reciente
          for (const n of userNotifications) {
            const yesterday = new Date(today)
            yesterday.setDate(yesterday.getDate() - 1)

            const { data: existing } = await supabase
              .from('notifications')
              .select('id')
              .eq('user_id', notifUserId)
              .eq('type', n.type)
              .eq('title', n.title)
              .gte('created_at', yesterday.toISOString())
              .limit(1)

            if (!existing || existing.length === 0) {
              await supabase
                .from('notifications')
                .insert({
                  user_id: notifUserId,
                  tenant_id: tenantId,
                  type: n.type,
                  title: n.title,
                  message: n.message,
                  link: n.link
                })
            }
          }
        }
      }

      results.push({
        tenantId,
        notificationsGenerated: notifications.length
      })
    }

    console.log('Notifications generated successfully:', results.length, 'tenants processed')

    return new Response(
      JSON.stringify({ success: true, results }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )

  } catch (error) {
    console.error('Error generating notifications:', error)
    const errorMessage = error instanceof Error ? error.message : 'Unknown error'
    return new Response(
      JSON.stringify({ error: errorMessage }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )
  }
})
