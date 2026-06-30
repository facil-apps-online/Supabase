import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient, SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';

// Definición de la estructura de la respuesta de la API de tasas de cambio
interface ExchangeRateResponse {
  result: string;
  base_code: string;
  conversion_rates: {
    [key: string]: number;
  };
}

// Función para crear un cliente de Supabase con privilegios de servicio
// para poder escribir en la base de datos desde la función.
const createAdminClient = () => {
  return createClient(
    Deno.env.get('SUPABASE_URL') ?? '',
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
    {
      auth: {
        // Esto es importante para que el cliente no intente gestionar sesiones de usuario.
        autoRefreshToken: false,
        persistSession: false,
      },
    }
  );
};

serve(async (req) => {
  try {
    // 1. Crear el cliente de Supabase con rol de servicio.
    const supabaseAdmin = createAdminClient();

    // 2. Obtener la clave de la API de tasas de cambio de los secretos
    const exchangeRateApiKey = Deno.env.get('EXCHANGE_RATE_API_KEY');
    if (!exchangeRateApiKey) {
      throw new Error('EXCHANGE_RATE_API_KEY no está definida en los secretos de la función.');
    }

    // 3. Llamar a la API de tasas de cambio
    const response = await fetch(`https://v6.exchangerate-api.com/v6/${exchangeRateApiKey}/latest/USD`);
    if (!response.ok) {
      throw new Error(`Error al obtener las tasas de cambio: ${response.statusText}`);
    }
    const exchangeData: ExchangeRateResponse = await response.json();

    if (exchangeData.result !== 'success') {
      throw new Error('La respuesta de la API de tasas de cambio no fue exitosa.');
    }

    // 4. Preparar los datos para la inserción en la tabla de caché
    const ratesToUpsert = Object.entries(exchangeData.conversion_rates).map(([target_code, rate]) => ({
      base_currency_code: exchangeData.base_code,
      target_currency_code: target_code,
      rate: rate,
      last_updated_at: new Date().toISOString(),
    }));

    // 5. Usar 'upsert' para actualizar o insertar las tasas en la tabla 'exchange_rates'
    const { error: upsertError } = await supabaseAdmin
      .from('exchange_rates')
      .upsert(ratesToUpsert, { onConflict: 'base_currency_code,target_currency_code' });

    if (upsertError) {
      throw upsertError;
    }

    // 6. Devolver una respuesta exitosa
    return new Response(
      JSON.stringify({ message: `Se actualizaron ${ratesToUpsert.length} tasas de cambio.` }),
      { headers: { 'Content-Type': 'application/json' }, status: 200 }
    );

  } catch (error) {
    // Manejo de errores
    return new Response(
      JSON.stringify({ error: error.message }),
      { headers: { 'Content-Type': 'application/json' }, status: 500 }
    );
  }
});