// supabase/Core/supabase/functions/google-oauth-callback/index.ts

import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { encrypt } from '../_shared/security.ts';
import { decode } from "https://deno.land/std@0.208.0/encoding/base64.ts";
import { corsHeaders } from '../_shared/cors.ts';


const GOOGLE_CLIENT_ID = Deno.env.get('GOOGLE_CLIENT_ID');
const GOOGLE_CLIENT_SECRET = Deno.env.get('GOOGLE_CLIENT_SECRET');
const FALLBACK_REDIRECT_URL = Deno.env.get('SUPERADMIN_APP_URL') || 'http://localhost:5173/integrations';


serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  // This is the URL of *this* function.
  const REDIRECT_URI = `${Deno.env.get('SUPABASE_URL')}/functions/v1/google-oauth-callback`;

  let redirectUrl = FALLBACK_REDIRECT_URL; // Initialize with fallback

  try {
    // Check for required environment variables
    const requiredEnv = [
      'GOOGLE_CLIENT_ID', 'GOOGLE_CLIENT_SECRET', 'SUPABASE_URL', 'SUPABASE_SERVICE_ROLE_KEY', 'FAO_ENCRYPTION_KEY'
    ];
    for (const env of requiredEnv) {
      if (!Deno.env.get(env)) {
        throw new Error(`Missing required environment variable: ${env}`);
      }
    }

    const url = new URL(req.url);
    const code = url.searchParams.get('code');
    const state = url.searchParams.get('state');

    if (!code || !state) {
      throw new Error('Missing code or state from Google OAuth callback.');
    }
    
    // The state is base64 encoded JSON
    const { tenantId, provider, finalRedirectUrl } = JSON.parse(new TextDecoder().decode(decode(state)));
    
    // Use the dynamic redirect URL from state if available
    if (finalRedirectUrl) {
      redirectUrl = finalRedirectUrl;
    }

    if (!tenantId || !provider) {
        throw new Error('Invalid state parameter. TenantId or provider missing.');
    }
    
    // 1. Exchange authorization code for tokens
    const tokenResponse = await fetch('https://oauth2.googleapis.com/token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        code,
        client_id: GOOGLE_CLIENT_ID,
        client_secret: GOOGLE_CLIENT_SECRET,
        redirect_uri: REDIRECT_URI,
        grant_type: 'authorization_code',
      }),
    });

    if (!tokenResponse.ok) {
      const errorBody = await tokenResponse.json();
      throw new Error(`Google token exchange failed: ${JSON.stringify(errorBody)}`);
    }

    const tokens = await tokenResponse.json();
    const { access_token, refresh_token } = tokens;

    if (!refresh_token) {
        console.warn(`No refresh token returned for tenant ${tenantId}. This is normal if consent was already granted.`);
    }

    // 2. Get user info from Google
    const userInfoResponse = await fetch('https://www.googleapis.com/oauth2/v3/userinfo', {
        headers: { Authorization: `Bearer ${access_token}` },
    });
    if (!userInfoResponse.ok) {
        throw new Error('Failed to fetch user info from Google.');
    }
    const userInfo = await userInfoResponse.json();
    const userEmail = userInfo.email;

    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    // Fetch platform_id from the tenant
    const { data: tenantData, error: tenantError } = await supabaseAdmin
      .from('tenants')
      .select('platform_id')
      .eq('id', tenantId)
      .single();

    if (tenantError) {
      throw new Error(`Could not fetch tenant to determine platform: ${tenantError.message}`);
    }
    if (!tenantData) {
        throw new Error(`Tenant with ID ${tenantId} not found.`);
    }

    const upsertData: any = {
      tenant_id: tenantId,
      platform_id: tenantData.platform_id, // Add the platform_id
      provider: provider,
      access_token: access_token,
      account_email: userEmail,
      updated_at: new Date().toISOString(),
      environment: 'production', // Or determine dynamically if needed
      is_active: true,
    };

    // 3. Encrypt and include refresh token ONLY if it was provided
    if (refresh_token) {
        const { encrypted, nonce } = await encrypt(refresh_token);
        upsertData.encrypted_credentials = encrypted;
        upsertData.nonce = nonce;
    }

    // 4. Save credentials to database
    const { error: dbError } = await supabaseAdmin
      .from('tenant_integrations')
      .upsert(upsertData, { onConflict: 'tenant_id, provider, environment' });

    if (dbError) {
      console.error('Database error:', dbError);
      throw dbError;
    }

    // 5. Redirect user back to the Superadmin UI
    return Response.redirect(`${redirectUrl}?success=true&provider=${provider}&tenantId=${tenantId}&accountEmail=${encodeURIComponent(userEmail)}`, 303);

  } catch (error) {
    console.error('Error in Google OAuth callback:', error);
    // Redirect with error message
    const errorUrl = new URL(redirectUrl);
    errorUrl.searchParams.set('success', 'false');
    errorUrl.searchParams.set('error', error.message);
    return Response.redirect(errorUrl.toString(), 303);
  }
});
