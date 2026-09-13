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
  invite_ref?: string;
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
    const { recaptcha_token, platform_id, invite_ref, ...tenant_data } = payload;

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

    // 2.1 Redención de invitación de vendedor (best-effort, no bloquea el registro).
    if (invite_ref) {
      try {
        console.log(`Paso 2.1: Intentando redimir invite_ref '${invite_ref}'...`);
        const { data: invitation, error: inviteLookupError } = await coreSupabase
          .from('vendor_invitations')
          .select('id, vendor_user_id, platform_id, status, trial_days_override')
          .eq('invite_token', invite_ref)
          .not('status', 'in', '(cuenta_creada,activo,activo_con_plan,perdido,duplicado)')
          .maybeSingle();

        if (inviteLookupError) {
          console.error('Error al buscar la invitación:', inviteLookupError.message);
        } else if (invitation) {
          const { error: vendorTenantError } = await coreSupabase.from('vendor_tenants').insert({
            user_id: invitation.vendor_user_id,
            tenant_id: createdTenantId,
            platform_id: invitation.platform_id,
          });
          if (vendorTenantError) console.error('Error al vincular vendor_tenants:', vendorTenantError.message);

          const { error: inviteUpdateError } = await coreSupabase
            .from('vendor_invitations')
            .update({ status: 'cuenta_creada', tenant_id: createdTenantId })
            .eq('id', invitation.id);
          if (inviteUpdateError) console.error('Error al actualizar la invitación:', inviteUpdateError.message);

          // Activa el trial del plan de la plataforma (si tiene uno configurado). El tope de
          // días SIEMPRE es el duration_days del plan — trial_days_override solo puede reducirlo,
          // la función lo aplica con LEAST(...) sin importar lo que traiga la invitación.
          const { data: trialResult, error: trialRpcError } = await coreSupabase.rpc('activate_vendor_trial_subscription', {
            p_tenant_id: createdTenantId,
            p_platform_id: invitation.platform_id,
            p_requested_days: invitation.trial_days_override,
          });
          if (trialRpcError) {
            console.error('Error al invocar activate_vendor_trial_subscription:', trialRpcError.message);
          } else if (!trialResult?.success) {
            console.log(`No se activó trial para tenant ${createdTenantId}: ${trialResult?.error}`);
          } else {
            console.log(`Trial activado para tenant ${createdTenantId}: ${trialResult.days_granted} días.`);
          }

          console.log(`Invitación '${invite_ref}' redimida para tenant ${createdTenantId}.`);
        } else {
          console.log(`No se encontró una invitación válida para invite_ref '${invite_ref}'.`);
        }
      } catch (inviteError) {
        console.error('Error inesperado redimiendo la invitación (no bloquea el registro):', inviteError.message);
      }
    } else {
      // 2.1 Registro directo (sin vendedor): solo se activa el trial si la plataforma tiene un
      // plan is_default_trial y además is_active = true. A diferencia del canal de vendedor, aquí
      // sí se respeta ese flag — es como el admin de la plataforma prende/apaga el trial
      // automático para altas orgánicas.
      try {
        console.log('Paso 2.1: Registro directo, verificando si hay trial activo para la plataforma...');
        const { data: trialPlan, error: trialPlanError } = await coreSupabase
          .from('subscription_plans')
          .select('id')
          .eq('platform_id', platform_id)
          .eq('is_default_trial', true)
          .eq('is_active', true)
          .maybeSingle();

        if (trialPlanError) {
          console.error('Error al buscar el plan de prueba de la plataforma:', trialPlanError.message);
        } else if (trialPlan) {
          const { data: trialResult, error: trialRpcError } = await coreSupabase.rpc('activate_vendor_trial_subscription', {
            p_tenant_id: createdTenantId,
            p_platform_id: platform_id,
          });
          if (trialRpcError) {
            console.error('Error al invocar activate_vendor_trial_subscription:', trialRpcError.message);
          } else if (!trialResult?.success) {
            console.log(`No se activó trial para tenant ${createdTenantId}: ${trialResult?.error}`);
          } else {
            console.log(`Trial activado (registro directo) para tenant ${createdTenantId}: ${trialResult.days_granted} días.`);
          }
        } else {
          console.log(`La plataforma ${platform_id} no tiene un plan de prueba activo (is_active=true); no se activa trial automático.`);
        }
      } catch (trialError) {
        console.error('Error inesperado activando el trial de registro directo (no bloquea el registro):', trialError.message);
      }
    }

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