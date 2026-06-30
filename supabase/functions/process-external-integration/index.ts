// C:\Desarrollos\supabase\supabase\functions\process-external-integration\index.ts

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
// import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.38.5'; // Not directly used in this Edge Function

// Helper function for decryption (placeholder - actual implementation depends on encryption method)
// In a real scenario, this might involve a more robust decryption library or a separate secure service.
function decrypt(encryptedData: string, nonce: string, key: string): string {
  // This is a simplified placeholder. Actual decryption would be more complex.
  // For PGP decryption, you'd need a Deno-compatible PGP library or call another secure service.
  // For now, we'll assume the key is used directly if it's a simple symmetric encryption.
  console.warn("Decryption is a placeholder. Implement actual secure decryption.");
  // Example: If key is a simple XOR key, or if encryptedData is just base64 encoded.
  // This needs to match how it's encrypted in the DB.
  // For demonstration, assuming encryptedData is a base64 encoded JSON string of credentials.
  try {
    return atob(encryptedData); 
  } catch (e) {
    throw new Error("Failed to base64 decode encrypted credentials. Ensure they are base64 encoded.");
  }
}

// Function to dynamically map Glamtica data to provider's API schema
function mapDataToProviderSchema(glamticaData: any, apiSchema: any): any {
  const mappedData: any = {};

  const resolvePath = (obj: any, path: string[]) => {
    let value = obj;
    for (const p of path) {
      if (value && typeof value === 'object' && value.hasOwnProperty(p)) {
        value = value[p];
      } else {
        return undefined; // Path not found
      }
    }
    return value;
  };

  const processSchema = (schemaPart: any, glamticaSource: any, target: any) => {
    if (!schemaPart || typeof schemaPart !== 'object') return;

    for (const key in schemaPart) {
      if (schemaPart.hasOwnProperty(key)) {
        const fieldDef = schemaPart[key];

        if (fieldDef && typeof fieldDef === 'object') {
          if (fieldDef.glamticaMap) {
            const path = fieldDef.glamticaMap.replace(/{{|}}/g, '').split('.');
            const value = resolvePath(glamticaSource, path);
            if (value !== undefined) {
              target[key] = value;
            }
          } else if (fieldDef.type === 'object' && fieldDef.children) {
            target[key] = {};
            processSchema(fieldDef.children, glamticaSource, target[key]);
          } else if (Array.isArray(fieldDef) && fieldDef.length > 0) {
            // Handle arrays of items
            // Assuming the first element of the array schema defines the structure for each item
            const itemSchema = fieldDef[0];
            if (itemSchema.glamticaMap) { // If the array itself has a glamticaMap (e.g., for a simple array of strings)
                const path = itemSchema.glamticaMap.replace(/{{|}}/g, '').split('.');
                const value = resolvePath(glamticaSource, path);
                if (value !== undefined && Array.isArray(value)) {
                    target[key] = value;
                }
            } else if (itemSchema.type === 'object') {
                // Assuming glamticaData has a corresponding array of objects
                const glamticaArrayKey = key; // Assuming the key in the target matches the key in glamticaData
                if (glamticaSource[glamticaArrayKey] && Array.isArray(glamticaSource[glamticaArrayKey])) {
                    target[key] = glamticaSource[glamticaArrayKey].map((itemSource: any) => {
                        const itemTarget: any = {};
                        processSchema(itemSchema, itemSource, itemTarget); // Recursively process each item
                        return itemTarget;
                    });
                }
            }
          } else {
            // If no glamticaMap and not a complex type, copy as is (might be a literal or default)
            target[key] = fieldDef; // This might need refinement based on actual apiSchema structure
          }
        }
      }
    }
  };

  processSchema(apiSchema, glamticaData, mappedData);
  return mappedData;
}


serve(async (req) => {
  try {
    const { 
      tenant_id,
      document_id,
      glamtica_invoice_data,
      provider_api_schema,
      provider_http_headers,
      provider_endpoints,
      tenant_encrypted_credentials,
      tenant_nonce,
      tenant_environment,
      http_method,
      body_format,
    } = await req.json();

    // 1. Decrypt credentials
    // The GLAMTICA_ENCRYPTION_KEY should be set as a Deno environment variable in Supabase.
    const GLAMTICA_ENCRYPTION_KEY = Deno.env.get('GLAMTICA_ENCRYPTION_KEY'); 

    if (!GLAMTICA_ENCRYPTION_KEY) {
      throw new Error('GLAMTICA_ENCRYPTION_KEY is not set in environment variables.');
    }

    // Placeholder decryption: Assuming tenant_encrypted_credentials is a base64 encoded JSON string
    // containing Dataico_account_id and Auth-token.
    // In a real scenario, this would use a robust decryption library (e.g., AES) with GLAMTICA_ENCRYPTION_KEY and tenant_nonce.
    const decryptedCredentialsJson = decrypt(tenant_encrypted_credentials, tenant_nonce, GLAMTICA_ENCRYPTION_KEY);
    const decryptedCredentials = JSON.parse(decryptedCredentialsJson);

    const dataicoAccountId = decryptedCredentials.Dataico_account_id;
    const dataicoAuthToken = decryptedCredentials['Auth-token']; // Use bracket notation for hyphenated key

    if (!dataicoAccountId || !dataicoAuthToken) {
      throw new Error('Dataico account ID or Auth-token missing after decryption.');
    }

    // 2. Map Glamtica data to provider's API schema
    const providerRequestBody = mapDataToProviderSchema(glamtica_invoice_data, provider_api_schema);

    // 3. Construct HTTP Headers
    const headers: HeadersInit = {};
    for (const headerDef of provider_http_headers) {
      if (headerDef.name === 'Dataico_account_id') {
        headers[headerDef.name] = dataicoAccountId;
      } else if (headerDef.name === 'Auth-token') {
        headers[headerDef.name] = dataicoAuthToken;
      } else if (headerDef.value) {
        headers[headerDef.name] = headerDef.value;
      } else if (headerDef.value_from_config) {
        // This case is for values coming from config_schema, which we've already handled above
        // or if there are other generic config values.
        // For now, we assume Dataico_account_id and Auth-token are the only dynamic ones.
      }
    }

    // Ensure Content-Type is set correctly based on body_format
    if (body_format === 'JSON' && !headers['Content-Type']) {
      headers['Content-Type'] = 'application/json';
    }

    // 4. Make External API Call
    const targetUrl = provider_endpoints[tenant_environment];
    if (!targetUrl) {
      throw new Error(`Endpoint URL not found for environment: ${tenant_environment}`);
    }

    const fetchOptions: RequestInit = {
      method: http_method,
      headers: headers,
    };

    if (http_method !== 'GET' && http_method !== 'HEAD') {
      fetchOptions.body = JSON.stringify(providerRequestBody);
    }

    const apiResponse = await fetch(targetUrl, fetchOptions);
    const apiResponseData = await apiResponse.json();

    if (!apiResponse.ok) {
      throw new Error(`API call failed with status ${apiResponse.status}: ${JSON.stringify(apiResponseData)}`);
    }

    // 5. Return structured response to RPC
    return new Response(JSON.stringify({ success: true, dataico_response: apiResponseData }), {
      headers: { 'Content-Type': 'application/json' },
      status: 200,
    });

  } catch (error) {
    console.error('Edge Function error:', error.message);
    return new Response(JSON.stringify({ success: false, error: error.message }), {
      headers: { 'Content-Type': 'application/json' },
      status: 400,
    });
  }
});
