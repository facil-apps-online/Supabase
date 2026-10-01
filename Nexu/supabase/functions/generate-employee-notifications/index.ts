import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

// Genera notificaciones in-app dirigidas al EMPLEADO (employee_id en notifications).
// Dedupe: por (employee_id, type, link) en ventana de 24h. El link incluye un
// identificador único por recurso (?sig=, ?curso=, ?examen=, ?eval=, ?inc=) para
// que múltiples eventos del mismo tipo en el mismo empleado no se colapsen.
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: corsHeaders })

  try {
    const url = Deno.env.get('SUPABASE_URL')!
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const supabase = createClient(url, serviceKey)

    const now = new Date()
    const isoToday = now.toISOString().split('T')[0]
    const in30 = new Date(now); in30.setDate(in30.getDate() + 30)
    const iso30 = in30.toISOString().split('T')[0]
    const windowStart = new Date(now.getTime() - 24 * 60 * 60 * 1000).toISOString()

    interface EmailTemplateConfig {
      enabled: boolean;
      daysBeforeExpiry: number;
      subject: string;
      body: string;
    }
    interface EmailTemplates {
      examenesVencer: EmailTemplateConfig;
      cursosVencer: EmailTemplateConfig;
      firmasPendientes: EmailTemplateConfig;
      comitesVencer: EmailTemplateConfig;
      dotacionEntrega: EmailTemplateConfig;
      evaluacionesPendientes: EmailTemplateConfig;
      vigilanciaSeguimiento: EmailTemplateConfig;
    }
    function applyTemplate(template: string, vars: Record<string, string>): string {
      return template.replace(/\{\{(\w+)\}\}/g, (_, key) => vars[key] ?? `{{${key}}}`);
    }

    // Cargar templates globales (del primer tenant activo como fallback)
    const { data: globalTemplates } = await supabase
      .from('tenant_settings')
      .select('settings_data, tenant_id')
      .eq('setting_key', 'email-templates')
      .limit(1)
      .maybeSingle()
    const globalTemplatesMap: Partial<EmailTemplates> = (globalTemplates?.settings_data as any) || {}

    const created: any[] = []
    const skipped: any[] = []
    const templateCache = new Map<string, Partial<EmailTemplates>>()

    async function getTemplatesForTenant(tenantId: string): Promise<Partial<EmailTemplates>> {
      if (templateCache.has(tenantId)) return templateCache.get(tenantId)!
      const { data } = await supabase
        .from('tenant_settings')
        .select('settings_data')
        .eq('tenant_id', tenantId)
        .eq('setting_key', 'email-templates')
        .maybeSingle()
      const tmpl: Partial<EmailTemplates> = (data?.settings_data as any) || globalTemplatesMap
      templateCache.set(tenantId, tmpl)
      return tmpl
    }

    const pushIfNew = async (n: {
      tenant_id: string; employee_id: string; type: string;
      title: string; message: string; link: string;
    }) => {
      const { data: existing, error: selErr } = await supabase
        .from('notifications')
        .select('id')
        .eq('employee_id', n.employee_id)
        .eq('type', n.type)
        .eq('link', n.link)
        .gte('created_at', windowStart)
        .limit(1)
      if (selErr) { console.error('dedupe select error', selErr); return }
      if (existing && existing.length > 0) { skipped.push(n.link); return }
      const { error: insErr } = await supabase
        .from('notifications')
        .insert({ ...n, read: false })
      if (insErr) { console.error('insert error', insErr, n); return }
      created.push(n.link)
    }

    // 1. Firmas pendientes
    const { data: pendingSigs } = await supabase
      .from('signatures')
      .select('id, employee_id, tenant_id, document_type, document_name')
      .eq('status', 'pending')
    for (const s of pendingSigs ?? []) {
      if (!s.employee_id) continue
      const tmpl = await getTemplatesForTenant(s.tenant_id)
      const docName = s.document_name ?? s.document_type
      const vars = { nombre_documento: docName, nombre_empresa: '' }
      await pushIfNew({
        tenant_id: s.tenant_id, employee_id: s.employee_id, type: 'pendiente_firma',
        title: tmpl.firmasPendientes ? applyTemplate(tmpl.firmasPendientes.subject, vars) : 'Tienes documentos por firmar',
        message: tmpl.firmasPendientes ? applyTemplate(tmpl.firmasPendientes.body, vars) : `Documento: ${docName}`,
        link: `/Funcionarios/firmar?sig=${s.id}`,
      })
    }

    // 2. Cursos por vencer (30 días)
    const { data: courses } = await supabase
      .from('courses')
      .select('id, employee_id, tenant_id, course_name, expiry_date')
      .lte('expiry_date', iso30).gte('expiry_date', isoToday)
    for (const c of courses ?? []) {
      if (!c.employee_id) continue
      const tmpl = await getTemplatesForTenant(c.tenant_id)
      const vars = { nombre_curso: c.course_name, fecha_vencimiento: c.expiry_date, nombre_empresa: '' }
      await pushIfNew({
        tenant_id: c.tenant_id, employee_id: c.employee_id, type: 'curso_vencer',
        title: tmpl.cursosVencer ? applyTemplate(tmpl.cursosVencer.subject, vars) : 'Curso próximo a vencer',
        message: tmpl.cursosVencer ? applyTemplate(tmpl.cursosVencer.body, vars) : `"${c.course_name}" vence el ${c.expiry_date}`,
        link: `/Funcionarios/cursos?curso=${c.id}`,
      })
    }

    // 3. Exámenes por vencer (30 días)
    const { data: exams } = await supabase
      .from('exams')
      .select('id, employee_id, tenant_id, exam_type, expiry_date')
      .lte('expiry_date', iso30).gte('expiry_date', isoToday)
    for (const e of exams ?? []) {
      if (!e.employee_id) continue
      const tmpl = await getTemplatesForTenant(e.tenant_id)
      const vars = { tipo_examen: e.exam_type, fecha_vencimiento: e.expiry_date, nombre_empresa: '' }
      await pushIfNew({
        tenant_id: e.tenant_id, employee_id: e.employee_id, type: 'examen_vencer',
        title: tmpl.examenesVencer ? applyTemplate(tmpl.examenesVencer.subject, vars) : 'Examen médico próximo a vencer',
        message: tmpl.examenesVencer ? applyTemplate(tmpl.examenesVencer.body, vars) : `"${e.exam_type}" vence el ${e.expiry_date}`,
        link: `/Funcionarios/examenes?examen=${e.id}`,
      })
    }

    // 4. Evaluaciones pendientes
    const { data: evals } = await supabase
      .from('evaluations')
      .select('id, employee_id, tenant_id, status')
      .in('status', ['pendiente', 'en_progreso'])
    for (const ev of evals ?? []) {
      if (!ev.employee_id) continue
      const tmpl = await getTemplatesForTenant(ev.tenant_id)
      const vars = { periodo: ev.status, fecha_limite: 'N/A', nombre_empresa: '' }
      await pushIfNew({
        tenant_id: ev.tenant_id, employee_id: ev.employee_id, type: 'evaluacion_pendiente',
        title: tmpl.evaluacionesPendientes ? applyTemplate(tmpl.evaluacionesPendientes.subject, vars) : 'Evaluación pendiente',
        message: tmpl.evaluacionesPendientes ? applyTemplate(tmpl.evaluacionesPendientes.body, vars) : 'Tienes una evaluación por completar',
        link: `/Funcionarios/evaluaciones?eval=${ev.id}`,
      })
    }

    // 5. Incapacidades con cambio de estado en últimas 24h
    const { data: incs } = await supabase
      .from('incapacidades')
      .select('id, employee_id, tenant_id, estado, tipo, updated_at')
      .gte('updated_at', windowStart)
      .in('estado', ['aprobada', 'rechazada', 'transcrita_nomina'])
    for (const i of incs ?? []) {
      await pushIfNew({
        tenant_id: i.tenant_id, employee_id: i.employee_id, type: `incapacidad_${i.estado}`,
        title: 'Actualización de incapacidad',
        message: `Tu incapacidad (${i.tipo.replace(/_/g, ' ')}) ahora está: ${i.estado.replace(/_/g, ' ')}`,
        link: `/Funcionarios/incapacidades?inc=${i.id}`,
      })
    }

    return new Response(
      JSON.stringify({ success: true, created: created.length, skipped: skipped.length }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )
  } catch (error) {
    console.error('generate-employee-notifications error:', error)
    return new Response(
      JSON.stringify({ error: error instanceof Error ? error.message : 'Unknown error' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )
  }
})
