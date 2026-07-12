import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  // Expecting a GET request like: /functions/v1/dynamic-og-tags?slug=coca-cola
  const url = new URL(req.url);
  const slug = url.searchParams.get('slug');

  // Default values
  let title = 'NexuHR - Gestión Integral de Recursos Humanos';
  let description = 'Portal de Empleados y Sistema integral de administración de talento humano.';
  let image = 'https://www.nexuhr.pro/og-image.png';

  if (slug && slug !== 'Funcionarios') {
    try {
      const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
      const supabaseKey = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
      const supabase = createClient(supabaseUrl, supabaseKey);

      // Call the existing RPC function
      const { data, error } = await supabase.rpc('get_tenant_by_portal_slug', { p_slug: slug });
      
      if (!error && data) {
        const row = Array.isArray(data) ? data[0] : data;
        if (row && row.tenant_name) {
          title = `${row.tenant_name} - Portal del Empleado`;
          if (row.logo_url) {
            // Usar la red lh3 de Google para devolver la imagen pura sin redirecciones (vital para WhatsApp)
            image = `https://lh3.googleusercontent.com/d/${row.logo_url}=w1200-h630-p`;
          }
        }
      }
    } catch (err) {
      console.error("Error fetching tenant info for OG tags:", err);
    }
  }

  const html = `<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <title>${title}</title>
    <meta property="og:title" content="${title}" />
    <meta property="og:description" content="${description}" />
    <meta property="og:type" content="website" />
    <meta property="og:image" content="${image}" />
    <meta property="og:image:secure_url" content="${image}" />
    <meta property="og:image:type" content="image/png" />
    <meta property="og:image:width" content="1200" />
    <meta property="og:image:height" content="630" />
    <meta property="og:url" content="https://www.nexuhr.pro/${slug || ''}" />
    <meta name="twitter:card" content="summary_large_image" />
    <meta name="twitter:title" content="${title}" />
    <meta name="twitter:description" content="${description}" />
    <meta name="twitter:image" content="${image}" />
    <link rel="icon" href="https://www.nexuhr.pro/nexurh-icon-192.png" type="image/png" />
    <link rel="apple-touch-icon" href="https://www.nexuhr.pro/nexurh-icon-180.png" />
</head>
<body>
    <p>Redirigiendo...</p>
    <script>
        // Si un usuario real entra por accidente a esta URL, lo enviamos de vuelta a la app.
        window.location.replace('https://www.nexuhr.pro/${slug || ''}');
    </script>
</body>
</html>`;

  return new Response(html, {
    headers: { 
        ...corsHeaders,
        'Content-Type': 'text/html; charset=utf-8' 
    },
    status: 200
  });
});
