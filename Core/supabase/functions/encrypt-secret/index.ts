import { serve } from 'https://deno.land/std@0.204.0/http/server.ts';
import { encode as base64Encode } from 'https://deno.land/std@0.204.0/encoding/base64.ts';
import { createRemoteJWKSet, jwtVerify } from "npm:jose@5";

console.log('[encrypt-secret] Function loaded.');

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

// Helper to import key safely
async function importKey(keyString: string) {
  const keyData = new TextEncoder().encode(keyString.padEnd(32, '0').slice(0, 32));
  return await crypto.subtle.importKey(
    "raw",
    keyData,
    { name: "AES-GCM" },
    false,
    ["encrypt", "decrypt"]
  );
}

serve(async (req) => {
  // 1. Handle Preflight Options (CORS)
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    // 2. Manual JWT Verification (Required for ES256 tokens in new projects)
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      throw new Error('Authorization header is required.');
    }

    const token = authHeader.replace('Bearer ', '');
    const supabaseUrl = Deno.env.get('SUPABASE_URL') || 'https://lvdrwumtbhvbtolqgrwi.supabase.co';
    
    // Fetch public keys from the auth server to verify asymmetric signature
    const jwksUrl = new URL(`${new URL(supabaseUrl).origin}/auth/v1/.well-known/jwks.json`);
    const JWKS = createRemoteJWKSet(jwksUrl);
    
    // This will throw an error if the token is invalid or signed with a different key
    await jwtVerify(token, JWKS);
    
    // 3. Business Logic: Encryption
    const MASTER_KEY_STRING = Deno.env.get('FAO_ENCRYPTION_KEY');
    if (!MASTER_KEY_STRING) {
      console.error('[encrypt-secret] CRITICAL: FAO_ENCRYPTION_KEY secret is not set.');
      throw new Error('Configuration Error: Encryption key is missing on the server.');
    }

    if (req.method !== 'POST') {
      return new Response(JSON.stringify({ error: 'Method not allowed' }), {
        status: 405,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    const body = await req.json();
    const { dataToEncrypt } = body;

    if (!dataToEncrypt) {
      throw new Error('Missing parameter "dataToEncrypt".');
    }

    console.log('[encrypt-secret] Encrypting data...');
    const key = await importKey(MASTER_KEY_STRING);
    const iv = crypto.getRandomValues(new Uint8Array(12)); 
    const encryptedData = await crypto.subtle.encrypt(
      { name: "AES-GCM", iv: iv },
      key,
      new TextEncoder().encode(dataToEncrypt)
    );

    return new Response(
      JSON.stringify({
        encryptedData: base64Encode(encryptedData),
        iv: base64Encode(iv),
      }),
      {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      }
    );

  } catch (error) {
    console.error('[encrypt-secret] Error:', error.message);
    // Return 401 for auth errors, 500 for the rest
    const isAuthError = error.message.includes('JWT') || error.message.includes('auth') || error.message.includes('JWS');
    return new Response(JSON.stringify({ error: error.message }), {
      status: isAuthError ? 401 : 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});
