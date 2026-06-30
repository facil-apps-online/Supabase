import { encode, decode } from "https://deno.land/std@0.208.0/encoding/base64.ts";

const ENCRYPTION_KEY = Deno.env.get('FAO_ENCRYPTION_KEY');

async function getKey() {
  if (!ENCRYPTION_KEY) {
    throw new Error("FAO_ENCRYPTION_KEY is not set in environment variables.");
  }
  // Use a consistent key derivation method, ensuring the key is 32 bytes for AES-256.
  const keyData = new TextEncoder().encode(ENCRYPTION_KEY.slice(0, 32));
  return await crypto.subtle.importKey(
    "raw",
    keyData,
    { name: "AES-GCM", length: 256 },
    true,
    ["encrypt", "decrypt"]
  );
}

/**
 * Encrypts a string using AES-GCM and returns the encrypted data and nonce as Base64 strings.
 * @param data The string to encrypt.
 * @returns An object containing the Base64-encoded encrypted data and nonce.
 */
export async function encrypt(data: string): Promise<{ encrypted: string; nonce: string }> {
  const key = await getKey();
  const nonce = crypto.getRandomValues(new Uint8Array(12)); // 96-bit IV is recommended for AES-GCM.
  const encodedData = new TextEncoder().encode(data);

  const encryptedBuffer = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv: nonce },
    key,
    encodedData
  );

  return {
    encrypted: encode(encryptedBuffer),
    nonce: encode(nonce),
  };
}

/**
 * Decrypts a Base64-encoded string using AES-GCM.
 * @param encrypted The Base64-encoded encrypted data.
 * @param nonce The Base64-encoded nonce.
 * @returns The decrypted string.
 */
export async function decrypt(encrypted: string, nonce: string): Promise<string> {
  const key = await getKey();
  const encryptedBuffer = decode(encrypted);
  const nonceBuffer = decode(nonce);

  const decryptedBuffer = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: nonceBuffer },
    key,
    encryptedBuffer
  );

  return new TextDecoder().decode(decryptedBuffer);
}
