import { serve } from 'https://deno.land/std@0.204.0/http/server.ts';
import { decode as base64Decode } from 'https://deno.land/std@0.204.0/encoding/base64.ts';

const MASTER_KEY_STRING = Deno.env.get('GLAMTICA_ENCRYPTION_KEY');
if (!MASTER_KEY_STRING) {
  throw new Error('El secreto GLAMTICA_ENCRYPTION_KEY no está definido.');
}

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

    const { encryptedData, iv } = await req.json();
    if (!encryptedData || !iv) {
      throw new Error('Los parámetros "encryptedData" e "iv" son requeridos.');
    }

    const key = await importKey(MASTER_KEY_STRING);
    const ivBytes = base64Decode(iv);
    const encryptedBytes = base64Decode(encryptedData);

    const decryptedData = await crypto.subtle.decrypt(
      {
        name: "AES-GCM",
        iv: ivBytes,
      },
      key,
      encryptedBytes
    );

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
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});
