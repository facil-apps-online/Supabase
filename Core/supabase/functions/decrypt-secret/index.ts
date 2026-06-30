import { serve } from 'https://deno.land/std@0.204.0/http/server.ts';
import { decode as base64Decode } from 'https://deno.land/std@0.204.0/encoding/base64.ts';

console.log('[decrypt-secret] Function initializing...');

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
  console.log(`[decrypt-secret] Received request: ${req.method}`);

  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const MASTER_KEY_STRING = Deno.env.get('FAO_ENCRYPTION_KEY');
    if (!MASTER_KEY_STRING) {
      console.error('[decrypt-secret] CRITICAL: FAO_ENCRYPTION_KEY secret not found!');
      throw new Error('El secreto FAO_ENCRYPTION_KEY no está definido.');
    }
    console.log('[decrypt-secret] FAO_ENCRYPTION_KEY secret loaded successfully.');

    if (req.method !== 'POST') {
      return new Response(JSON.stringify({ error: 'Método no permitido' }), {
        status: 405,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    const { encryptedData, iv } = await req.json();
    console.log('[decrypt-secret] Payload received.');
    if (!encryptedData || !iv) {
      console.error('[decrypt-secret] Payload missing "encryptedData" or "iv".');
      throw new Error('Los parámetros "encryptedData" e "iv" son requeridos.');
    }

    console.log('[decrypt-secret] Importing key...');
    const key = await importKey(MASTER_KEY_STRING);
    console.log('[decrypt-secret] Key imported. Decoding data...');
    const ivBytes = base64Decode(iv);
    const encryptedBytes = base64Decode(encryptedData);
    console.log('[decrypt-secret] Data decoded. Starting decryption...');

    const decryptedData = await crypto.subtle.decrypt(
      {
        name: "AES-GCM",
        iv: ivBytes,
      },
      key,
      encryptedBytes
    );
    console.log('[decrypt-secret] Decryption successful.');

    return new Response(
      JSON.stringify({
        decryptedText: new TextDecoder().decode(decryptedData),
      }),
      {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      }
    );
  } catch (error) {
    console.error('[decrypt-secret] An error occurred in the main try-catch block:', error);
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});
