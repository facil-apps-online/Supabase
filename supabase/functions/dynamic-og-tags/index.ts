import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { getCoreSupabaseClient } from '../_shared/supabaseClients.ts';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

// Platform mappings
const PLATFORMS: Record<string, { id: string, name: string, defaultImage: string, defaultTitle: string, defaultDesc: string, icon192: string, icon180: string, baseUrl: string }> = {
  'glamtica': {
    id: 'ca9090c3-f6a3-46c3-af1d-6362e2942e5f',
    name: 'Glamtica',
    defaultImage: 'https://glamtica.app/glamtica.app.png',
    defaultTitle: 'Glamtica - Software para Salones de Belleza',
    defaultDesc: 'Sistema integral de reservas y administración para salones, barberías y spas.',
    icon192: 'https://glamtica.app/android-icon-192x192.png',
    icon180: 'https://glamtica.app/apple-icon-180x180.png',
    baseUrl: 'https://glamtica.app'
  },
  'tattoosuite': {
    id: '6a6f73c8-2224-4eaf-b40d-da41bd75958a',
    name: 'Tattoo Suite',
    defaultImage: 'https://tattoosuite.app/tattoosuite.app.png',
    defaultTitle: 'Tattoo Suite - Gestión para Estudios de Tatuaje',
    defaultDesc: 'Software especializado en administración y reservas para estudios de tatuajes.',
    icon192: 'https://tattoosuite.app/android-icon-192x192.png',
    icon180: 'https://tattoosuite.app/apple-icon-180x180.png',
    baseUrl: 'https://tattoosuite.app'
  }
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  const url = new URL(req.url);
  const countryIso = url.searchParams.get('country');
  const slug = url.searchParams.get('slug');
  const platformKey = url.searchParams.get('platform')?.toLowerCase() || '';

  const platformInfo = PLATFORMS[platformKey];

  if (!platformInfo) {
    return new Response('Plataforma no válida.', { status: 400 });
  }

  let title = platformInfo.defaultTitle;
  let description = platformInfo.defaultDesc;
  let image = platformInfo.defaultImage;
  const redirectUrl = `${platformInfo.baseUrl}/${countryIso || ''}/${slug || ''}`;

  if (countryIso && slug) {
    try {
      const coreSupabase = getCoreSupabaseClient();
      
      const { data, error } = await coreSupabase.rpc('get_tenant_for_microsite', {
        p_country_iso_code: countryIso.toUpperCase(),
        p_slug: slug,
        p_platform_id: platformInfo.id,
      });

      if (!error && data) {
        if (data.name) {
          title = `${data.name} | Reservas en Línea`;
          if (data.logo_url) {
            image = `https://lh3.googleusercontent.com/d/${data.logo_url}=w1200-h630-p`;
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
    <meta property="og:url" content="${redirectUrl}" />
    
    <meta name="twitter:card" content="summary_large_image" />
    <meta name="twitter:title" content="${title}" />
    <meta name="twitter:description" content="${description}" />
    <meta name="twitter:image" content="${image}" />
    
    <link rel="icon" href="${platformInfo.icon192}" type="image/png" />
    <link rel="apple-touch-icon" href="${platformInfo.icon180}" />
</head>
<body>
    <p>Redirigiendo...</p>
    <script>
        window.location.replace('${redirectUrl}');
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
