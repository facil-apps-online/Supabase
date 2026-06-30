/**
 * tenant-actions — Edge Function de NexuHR
 *
 * Punto de entrada principal del backend de NexuHR.
 * Gestiona todas las operaciones de negocio de RR.HH. a través de un switch de acciones.
 * Sigue el patrón del ecosistema FacilApps (Glamtica / Tattoo Suite).
 *
 * Acciones esenciales del ecosistema:
 *  - get-tenant-details   : Obtiene los datos del tenant del usuario autenticado
 *  - insert_system_alert  : Registra alertas/errores del sistema
 *  - get_branches         : Obtiene las sucursales del tenant (si aplica)
 *
 * Las acciones específicas de NexuHR se agregarán en este mismo switch
 * a medida que se desarrollen los módulos.
 */

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { getNexuAdminClient } from '../_shared/supabaseClients.ts';
import { jwtDecode } from 'https://esm.sh/jwt-decode@4.0.0';

interface RequestBody {
  action: string;
  payload?: any;
}

Deno.serve(async (req) => {
  console.log('--- Nueva Invocación a tenant-actions [NexuHR] ---');
  console.log('Método:', req.method);

  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const body = await req.json();
    const { action, payload } = body as RequestBody;
    console.log('Acción recibida:', action);
    console.log('Payload recibido:', JSON.stringify(payload));

    // Extraer tenant_id del JWT del usuario autenticado
    const authHeader = req.headers.get('Authorization');
    let tenantId: string | null = null;
    let userId: string | null = null;
    let platformId: string | null = null;

    if (authHeader) {
      try {
        const token = authHeader.replace('Bearer ', '');
        const decoded: any = jwtDecode(token);
        userId = decoded.sub || null;

        // El tenant_id activo viene en el app_metadata > assignments
        const assignments = decoded.app_metadata?.assignments || [];
        if (assignments.length > 0) {
          // Por convención, el primer assignment activo es el contexto actual
          tenantId = assignments[0]?.tenant_id || null;
          platformId = assignments[0]?.platform_id || null;
        }
      } catch (jwtError) {
        console.warn('No se pudo decodificar el JWT:', jwtError);
      }
    }

    console.log(`Contexto - userId: ${userId}, tenantId: ${tenantId}, platformId: ${platformId}`);

    // Cliente Admin de NexuHR (bypass RLS)
    const supabaseAdmin = getNexuAdminClient();

    // Cliente estándar que respeta RLS (usando el JWT del usuario)
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      {
        global: {
          headers: { Authorization: authHeader || '' },
        },
      }
    );

    let responseData: any;

    switch (action) {

      // -----------------------------------------------------------------------
      // GET TENANT DETAILS — Información del tenant del usuario autenticado
      // -----------------------------------------------------------------------
      case 'get-tenant-details': {
        console.log('Iniciando acción: get-tenant-details');
        if (!tenantId) throw new Error('No se encontró un tenant_id en el JWT del usuario.');

        const { data: tenant, error } = await supabaseAdmin
          .from('tenants')
          .select('id, name, country_id, logo_url, created_at')
          .eq('id', tenantId)
          .single();

        if (error) throw new Error(`Error al obtener datos del tenant: ${error.message}`);

        responseData = tenant;
        break;
      }

      // -----------------------------------------------------------------------
      // GET BRANCHES — Sucursales del tenant (si NexuHR maneja multi-sede)
      // -----------------------------------------------------------------------
      case 'get_branches': {
        console.log('Iniciando acción: get_branches');
        const targetTenantId = payload?.tenantId || tenantId;
        if (!targetTenantId) throw new Error('Se requiere un tenantId para obtener las sucursales.');

        const { data: branches, error } = await supabaseAdmin
          .from('branches')
          .select('id, name, address, is_active')
          .eq('tenant_id', targetTenantId)
          .eq('is_active', true)
          .order('name', { ascending: true });

        if (error) throw new Error(`Error al obtener sucursales: ${error.message}`);

        responseData = branches || [];
        break;
      }

      // -----------------------------------------------------------------------
      // INSERT SYSTEM ALERT — Registra errores/alertas del sistema
      // -----------------------------------------------------------------------
      case 'insert_system_alert': {
        console.log('Iniciando acción: insert_system_alert');
        const { platform_id, type, message, details } = payload || {};

        const { error } = await supabaseAdmin
          .from('system_alerts')
          .insert({
            platform_id: platform_id || platformId,
            type: type || 'error',
            message: message || 'Error sin mensaje',
            details: details || {},
            created_at: new Date().toISOString(),
          });

        if (error) {
          console.warn('No se pudo registrar la alerta del sistema:', error.message);
          // No bloqueamos el flujo por un fallo en el logging
        }

        responseData = { success: true, message: 'Alerta registrada.' };
        break;
      }

      // -----------------------------------------------------------------------
      // === MÓDULOS DE NEXUHR ===
      // Las siguientes acciones se irán agregando conforme se desarrollen
      // los módulos de RR.HH.: empleados, nómina, vigilancias, cursos, etc.
      // -----------------------------------------------------------------------

      // TODO: get_employees
      // TODO: create_employee
      // TODO: update_employee
      // TODO: get_employee_detail
      // TODO: get_nomina_periods
      // TODO: create_nomina_period
      // TODO: get_vigilancias
      // TODO: get_cursos
      // TODO: get_dotacion
      // ... (se agregan en este switch a medida que se desarrollan los módulos)

      // -----------------------------------------------------------------------
      default:
        console.error('Acción no válida:', action);
        throw new Error(`La acción '${action}' no está implementada en tenant-actions [NexuHR].`);
    }

    console.log('Respuesta exitosa enviada.');
    return new Response(JSON.stringify(responseData), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200,
    });

  } catch (error: any) {
    console.error('--- ERROR EN tenant-actions [NexuHR] ---');
    console.error('Error:', error.message);
    return new Response(
      JSON.stringify({ success: false, error: error.message }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 200, // Siempre 200 — el cliente maneja el error por el flag
      }
    );
  }
});
