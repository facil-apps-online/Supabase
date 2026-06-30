import { createClient, SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';

let supabaseAdminClient: SupabaseClient | null = null;

/**
 * Obtiene el cliente de Supabase con rol de servicio para el proyecto actual.
 * Asume que las variables de entorno SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY
 * están disponibles y apuntan al proyecto Core donde se ejecuta la función.
 */
export function getSupabaseAdminClient(): SupabaseClient {
  if (supabaseAdminClient) {
    return supabaseAdminClient;
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');

  if (!supabaseUrl || !serviceRoleKey) {
    throw new Error('Las credenciales de Supabase (SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY) no están configuradas para el proyecto actual.');
  }

  supabaseAdminClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
    }
  });

  return supabaseAdminClient;
}
