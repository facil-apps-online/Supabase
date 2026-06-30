import { serve } from 'https://deno.land/std@0.177.0/http/server.ts'

// Helper para reemplazar placeholders en plantillas
const replacePlaceholders = (template, values) => {
  if (!template) return {};
  let body = JSON.stringify(template);
  for (const key in values) {
    const placeholder = new RegExp(`{{\s*${key}\s*}}`, 'g');
    body = body.replace(placeholder, values[key]);
  }
  return JSON.parse(body);
}

// Helper para construir el cuerpo de la solicitud
const buildBody = (provider) => {
  const sandboxValues = provider.configSchema.reduce((acc, field) => {
    acc[field.name] = field.sandboxValue;
    return acc;
  }, {});

  const format = provider.body_format?.format; // Asumimos que el objeto completo viene

  if (format === 'json') {
    return JSON.stringify(replacePlaceholders(provider.apiSchema, sandboxValues));
  }
  if (format === 'xml') {
    return replacePlaceholders(provider.body_template, sandboxValues);
  }
  return null; // Para GET, etc.
}

// Helper para construir las cabeceras
const buildHeaders = (provider) => {
  const headers = new Headers();
  
  // 1. Cabeceras estáticas
  provider.http_headers?.forEach(h => {
    headers.append(h.name, h.value);
  });

  // 2. Cabeceras de autenticación
  const authMethod = provider.auth_method?.method;
  const authConfig = provider.authentication_config;
  const sandboxValues = provider.configSchema.reduce((acc, field) => {
    acc[field.name] = field.sandboxValue;
    return acc;
  }, {});

  if (authMethod === 'bearer_token') {
    const token = sandboxValues[authConfig.token_credential_key];
    if (token) headers.append('Authorization', `Bearer ${token}`);
  }
  else if (authMethod === 'api_key_in_header') {
    const apiKey = sandboxValues[authConfig.key_credential_key];
    if (apiKey) headers.append(authConfig.header_name, apiKey);
  }
  else if (authMethod === 'basic_auth') {
    const user = sandboxValues[authConfig.user_credential_key];
    const pass = sandboxValues[authConfig.pass_credential_key];
    if (user && pass) {
      headers.append('Authorization', `Basic ${btoa(user + ":" + pass)}`);
    }
  }

  // 3. Content-Type si no está definido
  if (!headers.has('Content-Type')) {
    const format = provider.body_format?.format;
    if (format === 'json') headers.append('Content-Type', 'application/json');
    if (format === 'xml') headers.append('Content-Type', 'application/xml');
    if (format === 'form-urlencoded') headers.append('Content-Type', 'application/x-www-form-urlencoded');
  }

  return headers;
}


serve(async (req) => {
  // Manejo de CORS preflight request
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: { 
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    } });
  }

  try {
    const { action, payload } = await req.json();

    if (action === 'test') {
      const url = payload.endpoints?.test;
      if (!url) throw new Error("El endpoint de prueba no está definido.");

      const method = payload.http_method?.method || 'GET';
      const headers = buildHeaders(payload);
      const body = buildBody(payload);

      // Realizar la llamada a la API externa
      const externalResponse = await fetch(url, { method, headers, body });

      // Extraer datos de la respuesta externa
      const responseStatus = externalResponse.status;
      const responseBody = await externalResponse.text();
      const responseHeaders = Object.fromEntries(externalResponse.headers.entries());

      return new Response(
        JSON.stringify({
          status: responseStatus,
          headers: responseHeaders,
          body: responseBody,
        }),
        {
          headers: { 
            'Access-Control-Allow-Origin': '*',
            'Content-Type': 'application/json' 
          },
          status: 200,
        }
      )
    }

    // Placeholder para otras acciones
    if (action === 'execute') {
        // Lógica para producción irá aquí
    }

    return new Response(JSON.stringify({ error: 'Acción no válida' }), {
      headers: { 
        'Access-Control-Allow-Origin': '*',
        'Content-Type': 'application/json' 
      },
      status: 400,
    });

  } catch (error) {
    return new Response(JSON.stringify({ error: error.message }), {
      headers: { 
        'Access-Control-Allow-Origin': '*',
        'Content-Type': 'application/json' 
      },
      status: 500,
    });
  }
})
