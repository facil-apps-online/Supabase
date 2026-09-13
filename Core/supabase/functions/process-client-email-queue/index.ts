//supabase/functions/process-client-email-queue/index.ts
//
// Procesa por sondeo (igual patrón que process-whatsapp-queue): se auto-consulta los
// trabajos PENDING en cada invocación en vez de esperar un Database Webhook por fila,
// porque nunca existió un webhook ni un cron que invocara esta función — los correos
// simplemente se quedaban en PENDING para siempre. Ver invoke_process_email_queue()
// (migración 20260912000002) para el cron que la invoca cada minuto.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const DEFAULT_LANGUAGE_ID = 'f1154a99-712d-49fe-9c36-86e8360fbaa9'; // Español (Colombia)

async function processJob(supabaseAdmin: any, job: any) {
  await supabaseAdmin
    .from('client_email_queue')
    .update({ status: 'PROCESSING', attempts: (job.attempts || 0) + 1, last_attempt_at: new Date().toISOString() })
    .eq('id', job.id);

  try {
    // 1. Obtener el idioma del tenant (o usar el default si el trabajo no tiene tenant — ej.
    // correos de alcance plataforma, como el personal Superadmin de un cliente de Core).
    // tenants no tiene una columna default_language_id (uuid): guarda default_language_code
    // (ej. 'es'), que hay que resolver contra languages.iso_code.
    let languageId = DEFAULT_LANGUAGE_ID;
    if (job.tenant_id) {
      const { data: tenantSettings, error: tenantSettingsError } = await supabaseAdmin
        .from('tenants')
        .select('default_language_code')
        .eq('id', job.tenant_id)
        .single();

      if (tenantSettingsError) throw new Error(`Tenant not found: ${tenantSettingsError.message}`);

      if (tenantSettings.default_language_code) {
        const { data: language } = await supabaseAdmin
          .from('languages')
          .select('id')
          .eq('iso_code', tenantSettings.default_language_code)
          .maybeSingle();
        languageId = language?.id || DEFAULT_LANGUAGE_ID;
      }
    }

    // 2. Obtener la plantilla de correo. De alcance plataforma (tenant_id IS NULL) por ahora —
    // el filtro por platform_id evita traer la plantilla de otra plataforma con el mismo
    // template_type. job.platform_id puede ser NULL (ej. invitaciones internas de Facil Apps
    // Online que no son de ningún producto) — .eq(col, null) NO matchea filas NULL en SQL, hay
    // que usar .is() para ese caso.
    let templateQuery = supabaseAdmin
      .from('email_templates')
      .select('subject, body_html')
      .eq('template_type', job.template_type)
      .eq('language_id', languageId)
      .is('tenant_id', null);
    templateQuery = job.platform_id
      ? templateQuery.eq('platform_id', job.platform_id)
      : templateQuery.is('platform_id', null);

    const { data: template, error: templateError } = await templateQuery.single();

    if (templateError) throw new Error(`Template not found for type ${job.template_type}, platform ${job.platform_id}, language ${languageId}: ${templateError.message}`);

    // 3. Procesar la plantilla con los datos
    let processedBody = template.body_html;
    let processedSubject = template.subject;
    if (job.template_data) {
      for (const key in job.template_data) {
        processedBody = processedBody.replace(new RegExp(`{{${key}}}`, 'g'), job.template_data[key]);
        processedSubject = processedSubject.replace(new RegExp(`{{${key}}}`, 'g'), job.template_data[key]);
      }
    }

    // 4. Enviar el correo vía Brevo (API transaccional).
    const brevoApiKey = Deno.env.get('BREVO_API_KEY');
    const senderEmail = Deno.env.get('BREVO_SENDER_EMAIL');
    const senderName = Deno.env.get('BREVO_SENDER_NAME') ?? 'Facil Factura';
    if (!brevoApiKey || !senderEmail) {
      throw new Error('Faltan las variables de entorno BREVO_API_KEY / BREVO_SENDER_EMAIL en la función.');
    }

    const sendResponse = await fetch('https://api.brevo.com/v3/smtp/email', {
      method: 'POST',
      headers: { 'api-key': brevoApiKey, 'Content-Type': 'application/json', 'Accept': 'application/json' },
      body: JSON.stringify({
        sender: { email: senderEmail, name: senderName },
        to: [{ email: job.recipient_email }],
        subject: processedSubject,
        htmlContent: processedBody,
      }),
    });

    const sendData = await sendResponse.json().catch(() => ({}));
    if (!sendResponse.ok) throw new Error(`Brevo API error: ${sendData.message || JSON.stringify(sendData)}`);

    // 5. Marcar el trabajo como completado
    await supabaseAdmin.from('client_email_queue').update({ status: 'SENT' }).eq('id', job.id);
  } catch (sendError) {
    await supabaseAdmin.from('client_email_queue').update({ status: 'FAILED', error_message: sendError.message }).eq('id', job.id);
  }
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    const { data: jobs, error: fetchError } = await supabaseAdmin
      .from('client_email_queue')
      .select('*')
      .eq('status', 'PENDING')
      .limit(50);

    if (fetchError) throw fetchError;
    if (!jobs || jobs.length === 0) {
      return new Response(JSON.stringify({ message: 'No pending jobs.' }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
    }

    await Promise.all(jobs.map((job) => processJob(supabaseAdmin, job)));

    return new Response(JSON.stringify({ message: `Processed ${jobs.length} jobs.` }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
  } catch (error) {
    return new Response(JSON.stringify({ error: error.message }), { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
  }
});
