//supabase/functions/process-client-email-queue/index.ts

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*', 
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const { record: job } = await req.json();

    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    // Marcar el trabajo como en procesamiento
    await supabaseAdmin
      .from('client_email_queue')
      .update({ status: 'PROCESSING', attempts: (job.attempts || 0) + 1, last_attempt_at: new Date().toISOString() })
      .eq('id', job.id);

    try {
      // 1. Obtener el idioma del tenant (o usar uno por defecto)
      const { data: tenantSettings, error: tenantSettingsError } = await supabaseAdmin
        .from('tenants')
        .select('default_language_id')
        .eq('id', job.tenant_id)
        .single();
      
      if (tenantSettingsError) throw new Error(`Tenant not found: ${tenantSettingsError.message}`);
      
      const defaultLangId = 'f1154a99-712d-49fe-9c36-86e8360fbaa9'; // Default a Español si no hay nada
      const languageId = tenantSettings.default_language_id || defaultLangId;

      // 2. Obtener la plantilla de correo
      const { data: template, error: templateError } = await supabaseAdmin
        .from('email_templates')
        .select('subject, body_html')
        .eq('template_type', job.template_type)
        .eq('language_id', languageId)
        .single();

      if (templateError) throw new Error(`Template not found for type ${job.template_type} and language ${languageId}: ${templateError.message}`);

      // 3. Obtener la integración de Gmail específica para clientes del tenant
      let { data: integration, error: integrationError } = await supabaseAdmin
        .from('tenant_integrations')
        .select('id, access_token, encrypted_credentials, nonce, expires_at, account_email')
        .eq('provider', 'client_google_gmail') // <-- USANDO EL NUEVO PROVIDER
        .eq('tenant_id', job.tenant_id)
        .single();

      if (integrationError) throw new Error(`Client Gmail integration (client_google_gmail) not found for tenant ${job.tenant_id}: ${integrationError.message}`);

      let accessToken = integration.access_token;

      // 4. Refrescar el token de acceso si ha expirado
      if (!integration.expires_at || new Date(integration.expires_at) < new Date()) {
        if (!integration.encrypted_credentials || !integration.nonce) {
          throw new Error('La integración no tiene credenciales encriptadas o nonce para refrescar el token.');
        }

        const { data: decryptedResponse, error: decryptError } = await supabaseAdmin.functions.invoke(
          'decrypt-secret',
          { body: { encryptedData: integration.encrypted_credentials, iv: integration.nonce } }
        );

        if (decryptError) throw new Error(`Failed to invoke decrypt-secret function: ${decryptError.message}`);
        const refreshToken = decryptedResponse.decryptedText;
        if (!refreshToken) throw new Error('La respuesta de descifrado no contenía "decryptedText".');

        const tokenResponse = await fetch('https://oauth2.googleapis.com/token', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              client_id: Deno.env.get('GOOGLE_CLIENT_ID'),
              client_secret: Deno.env.get('GOOGLE_CLIENT_SECRET'),
              refresh_token: refreshToken,
              grant_type: 'refresh_token',
            }),
        });
        
        const tokenData = await tokenResponse.json();
        if (!tokenResponse.ok) throw new Error(`Token refresh failed: ${tokenData.error_description || JSON.stringify(tokenData)}`);

        accessToken = tokenData.access_token;
        const newExpiresAt = new Date(Date.now() + tokenData.expires_in * 1000).toISOString();

        await supabaseAdmin
          .from('tenant_integrations')
          .update({ access_token: accessToken, expires_at: newExpiresAt })
          .eq('id', integration.id);
      }

      // 5. Procesar la plantilla con los datos
      let processedBody = template.body_html;
      let processedSubject = template.subject;
      if (job.template_data) {
        for (const key in job.template_data) {
            processedBody = processedBody.replace(new RegExp(`{{${key}}}`, 'g'), job.template_data[key]);
            processedSubject = processedSubject.replace(new RegExp(`{{${key}}}`, 'g'), job.template_data[key]);
        }
      }

      // 6. Construir y enviar el correo
      const mimeMessage = `From: ${integration.account_email}\r\nTo: ${job.recipient_email}\r\nSubject: ${processedSubject}\r\nContent-Type: text/html; charset=UTF-8\r\n\r\n${processedBody}`;
      const base64Mime = btoa(mimeMessage);

      const sendResponse = await fetch('https://gmail.googleapis.com/gmail/v1/users/me/messages/send', {
        method: 'POST',
        headers: { 'Authorization': `Bearer ${accessToken}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ raw: base64Mime }),
      });

      const sendData = await sendResponse.json();
      if (!sendResponse.ok) throw new Error(`Gmail API error: ${sendData.error.message}`);
      
      // 7. Marcar el trabajo como completado
      await supabaseAdmin.from('client_email_queue').update({ status: 'SENT' }).eq('id', job.id);

    } catch (sendError) {
      // En caso de error, marcar como fallido
      await supabaseAdmin.from('client_email_queue').update({ status: 'FAILED', error_message: sendError.message }).eq('id', job.id);
      throw sendError; // Re-lanzar para que el bloque principal lo capture si es necesario
    }

    return new Response(JSON.stringify({ success: true }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } });

  } catch (e) {
    return new Response(JSON.stringify({ error: e.message }), { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
  }
});
