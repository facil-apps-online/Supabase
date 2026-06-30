import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { corsHeaders } from '../_shared/cors.ts';

// Definición de la estructura de la petición
interface RequestBody {
  tenantName: string;
  adminEmail: string;
}

Deno.serve(async (req) => {
  // Manejo de la petición pre-vuelo CORS
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const { tenantName, adminEmail }: RequestBody = await req.json();

    // Crear el cliente de Supabase con privilegios de administrador
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    // --- Lógica de negocio ---

    // 1. Obtener el ID de la plataforma
    const { data: platform, error: platformError } = await supabaseAdmin
      .from('platforms')
      .select('id')
      .limit(1)
      .single();

    if (platformError) throw platformError;
    if (!platform) throw new Error('No se encontró ninguna plataforma.');

    // 2. Obtener el ID del rol 'super_admin'
    const { data: role, error: roleError } = await supabaseAdmin
      .from('roles')
      .select('id')
      .eq('name', 'super_admin')
      .limit(1)
      .single();

    if (roleError) throw roleError;
    if (!role) throw new Error("No se encontró el rol 'super_admin'.");

    // 3. Crear el nuevo tenant
    const { data: newTenant, error: tenantError } = await supabaseAdmin
      .from('tenants')
      .insert({ name: tenantName, platform_id: platform.id })
      .select('id')
      .single();

    if (tenantError) throw tenantError;
    if (!newTenant) throw new Error('Falló la creación del tenant.');

    // 4. Construir los metadatos para el nuevo usuario
    const appMetadata = {
      tenant_id: newTenant.id,
      tenant_name: tenantName,
      role_id: role.id,
      role: 'super_admin',
      assignment_status: 'active',
    };

    // 5. Crear al usuario usando la API de Admin
    //    ¡Esta es la llamada que SÍ envía el correo de invitación!
    const { data: newUser, error: userError } = await supabaseAdmin.auth.admin.createUser({
      email: adminEmail,
      app_metadata: appMetadata,
      email_confirm: true, // Marcar como confirmado para que el usuario pueda iniciar sesión tras crear la contraseña
    });

    if (userError) throw userError;

    // --- Respuesta Exitosa ---
    return new Response(JSON.stringify({
      success: true,
      message: 'Tenant y superadministrador creados. Correo de invitación enviado.',
      userId: newUser.user.id,
      tenantId: newTenant.id,
    }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200,
    });

  } catch (error) {
    // --- Manejo de Errores ---
    return new Response(JSON.stringify({
      success: false,
      message: error.message,
    }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 500,
    });
  }
});
