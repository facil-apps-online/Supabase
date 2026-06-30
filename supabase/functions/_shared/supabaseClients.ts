
import { createClient, SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';

// Cache para los clientes de Supabase para evitar crearlos en cada invocación.
let tenantSupabaseClient: SupabaseClient | null = null;
let coreSupabaseClient: SupabaseClient | null = null;

/**
 * Obtiene el cliente de Supabase para la base de datos de Tenants.
 * Usa las variables de entorno estándar de Supabase.
 */
export function getTenantSupabaseClient(): SupabaseClient {
  if (tenantSupabaseClient) {
    return tenantSupabaseClient;
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');

  if (!supabaseUrl || !serviceRoleKey) {
    throw new Error('Tenant database credentials (SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY) are not configured.');
  }

  tenantSupabaseClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
    }
  });

  return tenantSupabaseClient;
}

/**
 * Obtiene el cliente de Supabase para la base de datos Core.
 * Usa las variables de entorno personalizadas para el proyecto Core.
 */
export function getCoreSupabaseClient(): SupabaseClient {
  if (coreSupabaseClient) {
    return coreSupabaseClient;
  }

  const coreSupabaseUrl = Deno.env.get('CORE_SUPABASE_URL');
  const coreServiceRoleKey = Deno.env.get('CORE_SUPABASE_SERVICE_ROLE_KEY');

  if (!coreSupabaseUrl || !coreServiceRoleKey) {
    throw new Error('Core database credentials (CORE_SUPABASE_URL, CORE_SUPABASE_SERVICE_ROLE_KEY) are not configured.');
  }

  coreSupabaseClient = createClient(coreSupabaseUrl, coreServiceRoleKey, {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
    }
  });

  return coreSupabaseClient;
}
