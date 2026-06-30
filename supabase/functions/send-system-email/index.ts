// supabase/functions/send-system-email/index.ts

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';

// --- NUEVA FUNCIÓN DE DESENCRIPTACIÓN NATIVA ---
async function decryptText(key: string, data: ArrayBuffer): Promise<string> {
  const keyBuffer = new TextEncoder().encode(key).slice(0, 32); // Ensure key is 32 bytes for AES-256
  const iv = new Uint8Array(12); // Nonce/IV, as pgcrypto uses a zero-nonce
  
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    keyBuffer,
    { name: "AES-GCM", length: 256 },
    false,
    ["decrypt"]
  );

  const decrypted = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: iv },
    cryptoKey,
    data
  );

  return new TextDecoder().decode(decrypted);
}
// --- FIN DE LA NUEVA FUNCIÓN ---


// ... (Interfaces sin cambios) ...
interface User {
  id: string;
  email: string;
  language_id: string;
  tenant_id: string | null;
  first_name: string | null;
  last_name: string | null;
}

interface TenantIntegration {
  id: string;
  access_token: string;
  encrypted_refresh_token: { type: 'Buffer', data: number[] }; // Ajustado al formato real
  expires_at: string;
  account_email: string;
}


serve(async (req) => {
  // ... (Lógica de servidor sin cambios hasta el refresco de token) ...
  try {
    const { userId, templateType, templateData } = await req.json();
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    // ... (Lógica de obtener usuario y plantilla sin cambios) ...
    const { data: user, error: userError } = await supabaseAdmin.from('users').select('id, email, language_id, tenant_id, first_name, last_name').eq('id', userId).single();
    if (userError) throw new Error(`Error fetching user: ${userError.message}`);
    if (!user) throw new Error(`User with ID ${userId} not found.`);
    const defaultLangId = 'f1154a99-712d-49fe-9c36-86e8360fbaa9';
    const languageId = user.language_id || defaultLangId;
    const { data: template, error: templateError } = await supabaseAdmin.from('email_templates').select('subject, body_html').eq('template_type', templateType).eq('language_id', languageId).single();
    if (templateError) throw new Error(`Error fetching template: ${templateError.message}`);
    if (!template) throw new Error(`Template ${templateType} for language ${languageId} not found.`);

    let { data: integration, error: integrationError } = await supabaseAdmin.from('tenant_integrations').select('id, access_token, encrypted_refresh_token, expires_at, account_email').eq('provider', 'google_gmail').eq('tenant_id', '00000000-0000-0000-0000-000000000000').single();
    if (integrationError) throw new Error(`Error fetching Gmail integration: ${integrationError.message}`);
    if (!integration) throw new Error('Gmail integration for superadmin not found.');

    let accessToken = integration.access_token;

    if (!integration.expires_at || new Date(integration.expires_at) < new Date()) {
      const encryptionKey = Deno.env.get('GLAMTICA_ENCRYPTION_KEY');
      if (!encryptionKey) throw new Error('Encryption key is not set.');

      // --- LÓGICA DE DESENCRIPTACIÓN ACTUALIZADA ---
      const encryptedData = new Uint8Array(integration.encrypted_refresh_token.data);
      const refreshToken = await decryptText(encryptionKey, encryptedData);
      // --- FIN DE LA ACTUALIZACIÓN ---

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
      if (!tokenResponse.ok) throw new Error(`Failed to refresh token: ${tokenData.error_description || JSON.stringify(tokenData)}`);

      accessToken = tokenData.access_token;
      const newExpiresAt = new Date(Date.now() + tokenData.expires_in * 1000).toISOString();

      await supabaseAdmin
        .from('tenant_integrations')
        .update({ access_token: accessToken, expires_at: newExpiresAt })
        .eq('id', integration.id);
    }

    // ... (Resto de la lógica de envío y logging sin cambios) ...
    let processedBody = template.body_html;
    let processedSubject = template.subject;
    for (const key in templateData) {
      processedBody = processedBody.replace(new RegExp(`{{${key}}}`, 'g'), templateData[key]);
      processedSubject = processedSubject.replace(new RegExp(`{{${key}}}`, 'g'), templateData[key]);
    }
    const mimeMessage = `From: ${integration.account_email}\r\nTo: ${user.email}\r\nSubject: ${processedSubject}\r\nContent-Type: text/html; charset=UTF-8\r\n\r\n${processedBody}`;
    const base64Mime = btoa(mimeMessage);
    const sendResponse = await fetch('https://gmail.googleapis.com/gmail/v1/users/me/messages/send', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${accessToken}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ raw: base64Mime }),
    });
    const sendData = await sendResponse.json();
    if (!sendResponse.ok) throw new Error(`Gmail API error: ${sendData.error.message}`);
    await supabaseAdmin.from('email_logs').insert({
      tenant_id: user.tenant_id || '00000000-0000-0000-0000-000000000000',
      recipient_email: user.email,
      status: 'SENT',
    });
    return new Response(JSON.stringify({ success: true, messageId: sendData.id }), {
      headers: { 'Content-Type': 'application/json' },
    });

  } catch (error) {
    // ... (Lógica de manejo de errores sin cambios) ...
    try {
      const supabaseAdmin = createClient(
        Deno.env.get('SUPABASE_URL') ?? '',
        Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
      );
      await supabaseAdmin.from('email_logs').insert({
        tenant_id: '00000000-0000-0000-0000-000000000000',
        recipient_email: 'unknown',
        status: 'FAILED',
        error_message: error.message,
      });
    } catch (logError) {
      console.error("Failed to log error:", logError);
    }
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { 'Content-Type': 'application/json' },
    });
  }
});
