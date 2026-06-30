import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { getSupabaseAdminClient } from '../_shared/supabaseClients.ts';

// Definición de tipos para los datos del formulario (solo los relevantes para el Core tenant)
interface FormData {
  platform_id: string;
  name: string;
  slug: string;
  country_id: string;
  default_language_code: string;
  default_currency_id: string;
  default_timezone: string;
  contact_phone?: string;
  whatsapp_phone?: string;
  commercial_email?: string;
  legal_name?: string;
  tax_id?: string;
  billing_address?: string;
  einvoicing_email?: string;
  physical_address_line1?: string;
  physical_address_line2?: string;
  physical_city?: string;
  physical_state?: string;
  physical_postal_code?: string;
  website?: string;
  latitude: number;
  longitude: number;
  recaptcha_token: string;
}

const RECAPTCHA_SECRET_KEY = Deno.env.get('RECAPTCHA_SECRET_KEY');

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

serve(async (req) => {
  console.log('--- Invocación de register-tenant (Core) ---');
  
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  const coreSupabase = getSupabaseAdminClient();
  let createdTenantId: string | null = null;

  try {
    const payload: FormData = await req.json();
    const { recaptcha_token, platform_id, ...tenant_data } = payload;

    // 1. Validación de reCAPTCHA
    console.log('Paso 1: Validando reCAPTCHA...');
    if (!RECAPTCHA_SECRET_KEY) throw new Error('El secreto de reCAPTCHA no está configurado.');
    const recaptchaUrl = 'https://www.google.com/recaptcha/api/siteverify';
    const response = await fetch(recaptchaUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: `secret=${RECAPTCHA_SECRET_KEY}&response=${recaptcha_token}`,
    });
    const recaptchaData = await response.json();
    if (!recaptchaData.success) {
      throw new Error('La verificación de reCAPTCHA ha fallado.');
    }
    console.log('reCAPTCHA validado exitosamente.');

    // 2. Crear el registro del tenant en la BD Core
    console.log('Paso 2 (Core DB): Creando registro de tenant...');
    const { data: newTenant, error: coreTenantError } = await coreSupabase
      .from('tenants')
      .insert({
        platform_id: platform_id,
        country_id: tenant_data.country_id,
        slug: tenant_data.slug,
        name: tenant_data.name,
      })
      .select('id')
      .single();
    if (coreTenantError) throw new Error(`Error al crear el tenant en la BD Core: ${coreTenantError.message}`);
    createdTenantId = newTenant.id; // Guardamos el ID para el rollback
    console.log(`Tenant creado en BD Core con ID: ${createdTenantId}`);

    console.log('--- Proceso de registro de tenant en Core finalizado exitosamente ---');
    return new Response(JSON.stringify({ 
        success: true, 
        message: 'Tenant Core registrado exitosamente.',
        tenant_id: createdTenantId
    }), {
      status: 200,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });

  } catch (error) {
    console.error('--- ERROR EN register-tenant (Core) ---');
    console.error('Error:', error.message);
    
    // --- Lógica de Rollback/Reversión (solo en Core) ---
    if (createdTenantId) {
        console.log(`Intentando revertir la creación del tenant con ID: ${createdTenantId} en Core.`);
        try {
            await coreSupabase.from('tenants').delete().eq('id', createdTenantId);
            console.log('Reversión de tenant completada en BD Core.');
        } catch (rollbackError) {
            console.error(`Error durante el rollback del tenant en BD Core: ${rollbackError.message}`);
        }
    }
    
    return new Response(JSON.stringify({ success: false, message: error.message }), {
      status: 200, 
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});