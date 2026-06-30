// Import necessary modules from Deno's standard library and Supabase.
import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.3';

// --- CORS Headers ---
// These headers are essential for allowing web browsers to call this function
// from a different origin (your web app's domain).
const corsHeaders = {
  'Access-Control-Allow-Origin': '*', // Replace with your app's domain for production
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey',
};

// --- HTML Response Templates ---
// Simple, user-friendly HTML pages to show the result of the action.
const createHtmlResponse = (message: string, color: string = '#333') => {
  return `
    <!DOCTYPE html>
    <html lang="es">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>Estado de la Cita</title>
      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; background-color: #f4f4f9; }
        .container { text-align: center; padding: 40px; border-radius: 8px; background-color: white; box-shadow: 0 4px 6px rgba(0,0,0,0.1); }
        h1 { color: ${color}; }
      </style>
    </head>
    <body>
      <div class="container">
        <h1>${message}</h1>
      </div>
    </body>
    </html>
  `;
};

// --- Main Function Logic ---
serve(async (req: Request) => {
  // Handle preflight OPTIONS request for CORS.
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    // --- Initialize Supabase Admin Client ---
    // This uses the service_role key for elevated privileges, necessary for server-side operations.
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    // --- Parse URL and Validate Input ---
    const url = new URL(req.url);
    const token = url.searchParams.get('token');
    const action = url.searchParams.get('action'); // 'confirm' or 'cancel'

    if (!token || !action || !['confirm', 'cancel'].includes(action)) {
      const html = createHtmlResponse('Datos inválidos en el enlace.', '#D32F2F');
      return new Response(html, { status: 400, headers: { ...corsHeaders, 'Content-Type': 'text/html' } });
    }

    // --- Find Attention by Token ---
    const { data: attention, error: findError } = await supabaseAdmin
      .from('attentions')
      .select('id, status')
      .eq('confirmation_token', token)
      .single();

    if (findError || !attention) {
      const html = createHtmlResponse('Enlace no válido o la cita ya ha sido actualizada.', '#FFC107');
      return new Response(html, { status: 404, headers: { ...corsHeaders, 'Content-Type': 'text/html' } });
    }

    // --- Update Attention Status and Invalidate Token ---
    const newStatus = action === 'confirm' ? 'confirmed' : 'cancelled';
    
    // Avoid re-confirming/cancelling
    if (attention.status === newStatus) {
        const message = `La cita ya se encontraba ${newStatus === 'confirmed' ? 'confirmada' : 'cancelada'}.`;
        const html = createHtmlResponse(message, '#1976D2');
        return new Response(html, { status: 200, headers: { ...corsHeaders, 'Content-Type': 'text/html' } });
    }

    const { error: updateError } = await supabaseAdmin
      .from('attentions')
      .update({
        status: newStatus,
        confirmation_token: null, // Invalidate the token after use
      })
      .eq('id', attention.id);

    if (updateError) {
      throw updateError;
    }

    // --- Return Success Response ---
    const successMessage = `¡Tu cita ha sido ${newStatus === 'confirmed' ? 'confirmada' : 'cancelada'} con éxito!`;
    const html = createHtmlResponse(successMessage, '#388E3C');
    return new Response(html, { status: 200, headers: { ...corsHeaders, 'Content-Type': 'text/html' } });

  } catch (error) {
    // --- Generic Error Handling ---
    console.error('Error processing attention update:', error);
    const html = createHtmlResponse('Ocurrió un error inesperado al procesar tu solicitud.', '#D32F2F');
    return new Response(html, { status: 500, headers: { ...corsHeaders, 'Content-Type': 'text/html' } });
  }
});