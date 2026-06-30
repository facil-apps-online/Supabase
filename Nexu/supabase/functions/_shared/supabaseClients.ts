import { createClient, SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';

// Cache para evitar crear clientes en cada invocación
let nexuAdminClient: SupabaseClient | null = null;
let coreClient: SupabaseClient | null = null;

/**
 * Cliente Admin de Supabase para la base de datos de NexuHR.
 * Usa el SUPABASE_SERVICE_ROLE_KEY para bypass de RLS.
 */
export function getNexuAdminClient(): SupabaseClient {
  if (nexuAdminClient) return nexuAdminClient;

  const url = Deno.env.get('SUPABASE_URL');
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');

  if (!url || !key) {
    throw new Error('NexuHR database credentials (SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY) are not configured.');
  }

  nexuAdminClient = createClient(url, key, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  return nexuAdminClient;
}

/**
 * Cliente de Supabase para la base de datos Core centralizada del ecosistema FacilApps.
 * Usa CORE_SUPABASE_URL y CORE_SUPABASE_SERVICE_ROLE_KEY.
 */
export function getCoreSupabaseClient(): SupabaseClient {
  if (coreClient) return coreClient;

  const url = Deno.env.get('CORE_SUPABASE_URL');
  const key = Deno.env.get('CORE_SUPABASE_SERVICE_ROLE_KEY');

  if (!url || !key) {
    throw new Error('Core database credentials (CORE_SUPABASE_URL, CORE_SUPABASE_SERVICE_ROLE_KEY) are not configured.');
  }

  coreClient = createClient(url, key, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  return coreClient;
}
