// supabase/functions/process-email-queue/index.ts

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

    await supabaseAdmin
      .from('email_queue')
      .update({ status: 'PROCESSING', attempts: (job.attempts || 0) + 1, last_attempt_at: new Date().toISOString() })
      .eq('id', job.id);

    try {
      const { data: user, error: userError } = await supabaseAdmin.from('users').select('id, email, language_id').eq('id', job.recipient_user_id).single();
      if (userError) throw new Error(`User not found: ${userError.message}`);

      // Dinámicamente encontrar el tenant_id del usuario (que en este caso es el superadmin)
      const { data: assignment, error: assignmentError } = await supabaseAdmin
        .from('user_assignments')
        .select('tenant_id')
        .eq('user_id', user.id)
        .limit(1)
        .single();
      
      if (assignmentError || !assignment) throw new Error(`Super admin tenant assignment not found: ${assignmentError?.message}`);

      const defaultLangId = 'f1154a99-712d-49fe-9c36-86e8360fbaa9';
      const languageId = user.language_id || defaultLangId;

      const { data: template, error: templateError } = await supabaseAdmin.from('email_templates').select('subject, body_html').eq('template_type', job.template_type).eq('language_id', languageId).single();
      if (templateError) throw new Error(`Template not found: ${templateError.message}`);

      // Usar el tenant_id del superadmin para encontrar la integración correcta
      let { data: integration, error: integrationError } = await supabaseAdmin.from('tenant_integrations').select('id, access_token, encrypted_credentials, nonce, expires_at, account_email').eq('provider', 'google_gmail').eq('tenant_id', assignment.tenant_id).single();
      if (integrationError) throw new Error(`Gmail integration not found for tenant ${assignment.tenant_id}: ${integrationError.message}`);

      let accessToken = integration.access_token;

      if (!integration.expires_at || new Date(integration.expires_at) < new Date()) {
        
        if (!integration.encrypted_credentials || !integration.nonce) {
          throw new Error('La integración no tiene credenciales encriptadas o nonce.');
        }

        // Desencriptar el refresh_token usando la Edge Function
        const { data: decryptedResponse, error: decryptError } = await supabaseAdmin.functions.invoke(
          'decrypt-secret',
          {
            body: {
              encryptedData: integration.encrypted_credentials,
              iv: integration.nonce,
            },
          }
        );

        if (decryptError) {
          throw new Error(`Failed to invoke decrypt-secret function: ${decryptError.message}`);
        }

        const refreshToken = decryptedResponse.decryptedText;
        if (!refreshToken) {
          throw new Error('La respuesta de descifrado no contenía "decryptedText".');
        }

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

      let processedBody = template.body_html;
      let processedSubject = template.subject;
      for (const key in job.template_data) {
        processedBody = processedBody.replace(new RegExp(`{{${key}}}`, 'g'), job.template_data[key]);
        processedSubject = processedSubject.replace(new RegExp(`{{${key}}}`, 'g'), job.template_data[key]);
      }
      const mimeMessage = `From: ${integration.account_email}\r\nTo: ${user.email}\r\nSubject: ${processedSubject}\r\nContent-Type: text/html; charset=UTF-8\r\n\r\n${processedBody}`;
      const base64Mime = btoa(mimeMessage);
      const sendResponse = await fetch('https://gmail.googleapis.com/gmail/v1/users/me/messages/send', {
        method: 'POST',
        headers: { 'Authorization': `Bearer ${accessToken}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ raw: base64Mime }),
      });
      const sendData = await sendResponse.json();
      if (!sendResponse.ok) throw new Error(`Gmail API error: ${sendData.error.message}`);
      await supabaseAdmin.from('email_queue').update({ status: 'SENT' }).eq('id', job.id);

    } catch (sendError) {
      await supabaseAdmin.from('email_queue').update({ status: 'FAILED', error_message: sendError.message }).eq('id', job.id);
    }

    return new Response(JSON.stringify({ success: true }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } });

  } catch (e) {
    return new Response(JSON.stringify({ error: e.message }), { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
  }
});
