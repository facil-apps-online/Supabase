import { serve } from 'https://deno.land/std@0.204.0/http/server.ts';
import { encode as base64Encode } from 'https://deno.land/std@0.204.0/encoding/base64.ts';

console.log('[encrypt-secret] Initializing function...');

const MASTER_KEY_STRING = Deno.env.get('GLAMTICA_ENCRYPTION_KEY');
if (!MASTER_KEY_STRING) {
  console.error('[encrypt-secret] CRITICAL: GLAMTICA_ENCRYPTION_KEY secret not found!');
  throw new Error('El secreto GLAMTICA_ENCRYPTION_KEY no está definido.');
}
console.log('[encrypt-secret] Master key secret loaded.');

// Importar la clave para la API Web Crypto
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

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

serve(async (req) => {
  console.log(`[encrypt-secret] Received request: ${req.method}`);
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    if (req.method !== 'POST') {
      return new Response(JSON.stringify({ error: 'Método no permitido' }), {
        status: 405,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    const { dataToEncrypt } = await req.json();
    console.log('[encrypt-secret] Received data to encrypt.');
    if (!dataToEncrypt) {
      throw new Error('El parámetro "dataToEncrypt" es requerido.');
    }

    console.log('[encrypt-secret] Starting encryption with Web Crypto API...');
    const key = await importKey(MASTER_KEY_STRING);
    const iv = crypto.getRandomValues(new Uint8Array(12)); // IV de 12 bytes es estándar para AES-GCM
    const encryptedData = await crypto.subtle.encrypt(
      {
        name: "AES-GCM",
        iv: iv,
      },
      key,
      new TextEncoder().encode(dataToEncrypt)
    );
    console.log('[encrypt-secret] Encryption successful. Encoding to Base64...');

    const encryptedBase64 = base64Encode(encryptedData);
    const ivBase64 = base64Encode(iv);
    console.log('[encrypt-secret] Base64 encoding successful.');

    return new Response(
      JSON.stringify({
        encryptedData: encryptedBase64,
        iv: ivBase64,
      }),
      {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      }
    );
  } catch (error) {
    console.error('[encrypt-secret] An unexpected error occurred:', error);
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});