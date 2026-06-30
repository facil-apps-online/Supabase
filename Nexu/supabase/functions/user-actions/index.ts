/**
 * user-actions — Edge Function de NexuHR
 * 
 * Gestiona todas las acciones relacionadas con usuarios y autenticación.
 * Sigue el patrón del ecosistema FacilApps (Glamtica / Tattoo Suite).
 * 
 * Acciones disponibles:
 *  - login-tenant              : Autenticación via email sintético + platform_id
 *  - refresh-user-metadata     : Rehidrata los app_metadata del usuario desde user_assignments
 *  - switch-assignment         : Valida un cambio de asignación
 *  - update-user-settings      : Actualiza user_metadata (nombre, avatar, etc.)
 *  - update-password           : Cambia la contraseña de un usuario
 *  - confirm-user-email        : Marca el email de un usuario como confirmado
 *  - get-user-metadata         : Devuelve el app_metadata de un usuario
 *  - check_user_exists_in_auth : Verifica si un usuario existe en auth.users
 *  - invite_or_assign_user_to_tenant : Crea o asigna un usuario a un tenant
 *  - create_auth_user          : Crea un usuario en auth.users (sin asignar a tenant)
 *  - generate-recovery-token   : Genera token de recuperación de contraseña
 *  - set-password-with-token   : Establece nueva contraseña usando token de recuperación
 */

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { getCoreSupabaseClient } from '../_shared/supabaseClients.ts';

interface RequestBody {
  action: string;
  payload: any;
}

Deno.serve(async (req) => {
  console.log('--- Nueva Invocación a user-actions [NexuHR] ---');
  console.log('Método:', req.method);

  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const body = await req.json();
    const { action, payload } = body as RequestBody;
    console.log('Acción recibida:', action);
    console.log('Payload recibido:', JSON.stringify(payload));

    // Cliente estándar (anon) — para operaciones como login
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? ''
    );

    // Cliente Admin — para operaciones que requieren bypass de RLS
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    let responseData: any;

    switch (action) {

      // -----------------------------------------------------------------------
      // LOGIN — Autenticación mediante email sintético (platform_id + email)
      // -----------------------------------------------------------------------
      case 'login-tenant': {
        console.log('Iniciando acción: login-tenant');
        const { email, password, platform_id } = payload;
        if (!email || !password || !platform_id) {
          throw new Error('El email, la contraseña y el platform_id son obligatorios.');
        }

        const synthetic_email = `${platform_id}_${email}`;
        console.log(`Intentando login con email sintético: ${synthetic_email}`);

        const { data, error } = await supabase.auth.signInWithPassword({
          email: synthetic_email,
          password,
        });

        if (error) {
          console.error('Error en signInWithPassword:', error);
          throw new Error(`Error de autenticación: ${error.message}`);
        }

        if (!data.session || !data.user) {
          throw new Error('Inicio de sesión fallido: no se recibió sesión o usuario.');
        }

        responseData = { success: true, session: data.session, user: data.user };
        break;
      }

      // -----------------------------------------------------------------------
      // REFRESH METADATA — Rehidrata app_metadata desde user_assignments en BD
      // -----------------------------------------------------------------------
      case 'refresh-user-metadata': {
        console.log('Iniciando acción: refresh-user-metadata');
        const { userId, platformId } = payload;
        if (!userId || !platformId) {
          throw new Error('El userId y el platformId son obligatorios.');
        }

        // 1. Consultar asignaciones activas del usuario para esta plataforma
        const { data: assignments, error: queryError } = await supabaseAdmin
          .from('user_assignments')
          .select(`
            assignment_id:id,
            tenant_id,
            role_id,
            branch_id,
            status,
            tenants!inner ( name, platform_id ),
            roles ( name, display_name ),
            branches ( name )
          `)
          .eq('user_id', userId)
          .eq('status', 'active')
          .eq('tenants.platform_id', platformId);

        if (queryError) {
          console.error('Error al obtener asignaciones:', queryError.message);
          throw new Error(`Error al consultar asignaciones: ${queryError.message}`);
        }

        // 2. Mapear al formato esperado en app_metadata
        const mappedAssignments = assignments.map((a: any) => ({
          assignment_id: a.assignment_id,
          tenant_id: a.tenant_id,
          tenant_name: a.tenants?.name || 'N/A',
          platform_id: a.tenants?.platform_id,
          role_id: a.role_id,
          role_name: a.roles?.name || 'N/A',
          role_display_name: a.roles?.display_name || 'N/A',
          branch_id: a.branch_id || null,
          branch_name: a.branches?.name || null,
          status: a.status,
        }));

        // 3. Actualizar app_metadata del usuario
        const { error: updateError } = await supabaseAdmin.auth.admin.updateUserById(
          userId,
          { app_metadata: { assignments: mappedAssignments } }
        );

        if (updateError) {
          console.error('Error al actualizar metadatos:', updateError.message);
          throw new Error(`Error al actualizar el usuario: ${updateError.message}`);
        }

        responseData = { success: true, message: 'Metadatos de usuario actualizados exitosamente.' };
        break;
      }

      // -----------------------------------------------------------------------
      // SWITCH ASSIGNMENT — Valida que la asignación pertenece al usuario
      // -----------------------------------------------------------------------
      case 'switch-assignment': {
        console.log('Iniciando acción: switch-assignment');
        const { userId, newAssignmentId } = payload;
        if (!userId || !newAssignmentId) {
          throw new Error('El userId y el newAssignmentId son obligatorios.');
        }

        const { data, error } = await supabaseAdmin
          .from('user_assignments')
          .select('id')
          .eq('id', newAssignmentId)
          .eq('user_id', userId)
          .single();

        if (error || !data) {
          console.error('Error al verificar la asignación:', error);
          throw new Error('La asignación seleccionada no es válida para este usuario.');
        }

        responseData = { success: true, message: 'Asignación verificada exitosamente.' };
        break;
      }

      // -----------------------------------------------------------------------
      // UPDATE USER SETTINGS — Actualiza user_metadata (perfil del usuario)
      // -----------------------------------------------------------------------
      case 'update-user-settings': {
        console.log('Iniciando acción: update-user-settings');
        const { userId, metadata } = payload;
        if (!userId || !metadata) {
          throw new Error('El userId y los metadatos son obligatorios.');
        }

        const { data: { user: currentUser }, error: getUserError } = await supabaseAdmin.auth.admin.getUserById(userId);
        if (getUserError) throw new Error(`Error al obtener usuario: ${getUserError.message}`);

        const updatedMetadata = { ...currentUser.user_metadata, ...metadata };

        const { data: updatedUser, error: updateError } = await supabaseAdmin.auth.admin.updateUserById(
          userId,
          { user_metadata: updatedMetadata }
        );

        if (updateError) throw new Error(`Error al actualizar metadatos: ${updateError.message}`);

        responseData = {
          success: true,
          message: 'Configuración de usuario actualizada.',
          user: updatedUser.user,
        };
        break;
      }

      // -----------------------------------------------------------------------
      // UPDATE PASSWORD — Cambia la contraseña de un usuario
      // -----------------------------------------------------------------------
      case 'update-password': {
        console.log('Iniciando acción: update-password');
        const { userId, newPassword } = payload;
        if (!userId || !newPassword) {
          throw new Error('El userId y la nueva contraseña son obligatorios.');
        }

        const { error: updateError } = await supabaseAdmin.auth.admin.updateUserById(
          userId,
          { password: newPassword }
        );

        if (updateError) throw new Error(`Error al actualizar la contraseña: ${updateError.message}`);

        responseData = { success: true, message: 'Contraseña actualizada exitosamente.' };
        break;
      }

      // -----------------------------------------------------------------------
      // CONFIRM USER EMAIL — Marca el email como confirmado
      // -----------------------------------------------------------------------
      case 'confirm-user-email': {
        console.log('Iniciando acción: confirm-user-email');
        const { email, platform_id } = payload;
        if (!email || !platform_id) {
          throw new Error('El email y el platform_id son obligatorios.');
        }

        const synthetic_email = `${platform_id}_${email}`;
        const { data: { users }, error: findError } = await supabaseAdmin.auth.admin.listUsers({ email: synthetic_email });
        if (findError) throw new Error(`Error al buscar usuario: ${findError.message}`);
        if (!users || users.length === 0) throw new Error('No se encontró el usuario para esta plataforma.');

        const { error: updateError } = await supabaseAdmin.auth.admin.updateUserById(
          users[0].id,
          { email_confirm: true }
        );

        if (updateError) throw new Error(`Error al confirmar email: ${updateError.message}`);

        responseData = { success: true, message: 'Email de usuario confirmado exitosamente.' };
        break;
      }

      // -----------------------------------------------------------------------
      // GET USER METADATA — Devuelve el app_metadata de un usuario
      // -----------------------------------------------------------------------
      case 'get-user-metadata': {
        console.log('Iniciando acción: get-user-metadata');
        const { userId } = payload;
        if (!userId) throw new Error('El userId es obligatorio.');

        const { data: user, error: userError } = await supabaseAdmin.auth.admin.getUserById(userId);
        if (userError) throw new Error(userError.message);

        responseData = { success: true, metadata: user?.app_metadata };
        break;
      }

      // -----------------------------------------------------------------------
      // CHECK USER EXISTS — Verifica si un usuario ya existe en auth.users
      // -----------------------------------------------------------------------
      case 'check_user_exists_in_auth': {
        console.log('Iniciando acción: check_user_exists_in_auth');
        const { email, platformId } = payload;
        if (!email || !platformId) {
          throw new Error('El email y el platformId son obligatorios.');
        }

        const synthetic_email = `${platformId}_${email}`;
        const { data: exists, error: rpcError } = await supabaseAdmin.rpc(
          'check_user_exists_in_auth_rpc',
          { p_email: synthetic_email }
        );

        if (rpcError) throw new Error(`Error al verificar usuario: ${rpcError.message}`);

        responseData = { success: true, exists };
        break;
      }

      // -----------------------------------------------------------------------
      // CREATE AUTH USER — Crea usuario en auth.users (sin asignar a tenant)
      // -----------------------------------------------------------------------
      case 'create_auth_user': {
        console.log('Iniciando acción: create_auth_user');
        const { email, password, platformId, firstName, lastName } = payload;
        if (!email || !password || !platformId) {
          throw new Error('El email, la contraseña y el platformId son obligatorios.');
        }

        const synthetic_email = `${platformId}_${email}`;

        const { data: authData, error: authError } = await supabaseAdmin.auth.admin.createUser({
          email: synthetic_email,
          password,
          email_confirm: true,
          user_metadata: {
            real_email: email,
            first_name: firstName || null,
            last_name: lastName || null,
          },
        });

        if (authError) throw new Error(`Error al crear usuario: ${authError.message}`);
        if (!authData.user) throw new Error('No se pudo obtener el objeto de usuario tras la creación.');

        responseData = { success: true, message: 'Usuario creado exitosamente.', user: authData.user };
        break;
      }

      // -----------------------------------------------------------------------
      // INVITE OR ASSIGN USER TO TENANT — Crea o asigna usuario + tenant en BD
      // -----------------------------------------------------------------------
      case 'invite_or_assign_user_to_tenant': {
        console.log('Iniciando acción: invite_or_assign_user_to_tenant');
        const { email, password, tenantId, roleName, branchName, platformId, firstName, lastName, tenantData } = payload;

        if (!email || !tenantId || !roleName || !platformId) {
          throw new Error('Los campos email, tenantId, roleName y platformId son obligatorios.');
        }

        const synthetic_email = `${platformId}_${email}`;
        let userToAssign;

        // Buscar si el usuario ya existe
        const { data: { users: allUsers }, error: findError } = await supabaseAdmin.auth.admin.listUsers();
        if (findError) throw new Error(`Error al obtener usuarios: ${findError.message}`);

        const existingUser = allUsers.find((u: any) => u.email === synthetic_email);

        if (existingUser) {
          userToAssign = existingUser;
          console.log(`Usuario existente encontrado: ${userToAssign.id}`);
        } else {
          console.log('Creando nuevo usuario en auth...');
          const { data: authData, error: authError } = await supabaseAdmin.auth.admin.createUser({
            email: synthetic_email,
            password: password || crypto.randomUUID(),
            email_confirm: true,
            user_metadata: { real_email: email, first_name: firstName, last_name: lastName },
          });
          if (authError) throw new Error(`Error al crear usuario: ${authError.message}`);
          if (!authData.user) throw new Error('La creación del usuario no devolvió un objeto de usuario.');
          userToAssign = authData.user;
          console.log(`Nuevo usuario creado: ${userToAssign.id}`);
        }

        // Delegar la lógica de BD a la RPC
        const { data: rpcResult, error: rpcError } = await supabaseAdmin.rpc('create_tenant_with_admin', {
          p_tenant_id: tenantId,
          p_user_id: userToAssign.id,
          p_platform_id: platformId,
          p_tenant_name: tenantData?.name || 'Nueva Empresa',
          p_country_id: tenantData?.country_id || null,
          p_email: email,
          p_currency_id: tenantData?.default_currency_id || null,
          p_timezone: tenantData?.default_timezone || 'UTC',
          p_phone: tenantData?.contact_phone || null,
          p_address: tenantData?.address || null,
          p_website: tenantData?.website || null,
          p_latitude: tenantData?.latitude || 0,
          p_longitude: tenantData?.longitude || 0,
          p_whatsapp_phone: tenantData?.whatsapp_phone || null,
          p_legal_name: tenantData?.legal_name || null,
          p_tax_id: tenantData?.tax_id || null,
          p_physical_address_line1: tenantData?.physical_address_line1 || null,
          p_physical_address_line2: tenantData?.physical_address_line2 || null,
          p_physical_city: tenantData?.physical_city || null,
          p_physical_state: tenantData?.physical_state || null,
          p_physical_postal_code: tenantData?.physical_postal_code || null,
          p_default_language_code: tenantData?.default_language_code || 'es',
        });

        if (rpcError) {
          console.error('Error en RPC create_tenant_with_admin:', rpcError);
          throw new Error(`Error en base de datos: ${rpcError.message}`);
        }

        responseData = {
          success: true,
          message: 'Usuario y Tenant procesados exitosamente.',
          user: userToAssign,
          db_details: rpcResult,
        };
        break;
      }

      // -----------------------------------------------------------------------
      // GENERATE RECOVERY TOKEN — Token para reseteo de contraseña
      // -----------------------------------------------------------------------
      case 'generate-recovery-token': {
        console.log('Iniciando acción: generate-recovery-token');
        const { email, platform_id } = payload;
        if (!email || !platform_id) throw new Error('El email y el platform_id son obligatorios.');

        const synthetic_email = `${platform_id}_${email}`;
        const { data: { users }, error: findError } = await supabaseAdmin.auth.admin.listUsers({ email: synthetic_email });
        if (findError) throw new Error(`Error al buscar usuario: ${findError.message}`);
        if (!users || users.length === 0) throw new Error('No se encontró un usuario con ese correo.');

        const user = users[0];
        const token = crypto.randomUUID();

        const { error: updateError } = await supabaseAdmin.auth.admin.updateUserById(
          user.id,
          {
            user_metadata: {
              ...user.user_metadata,
              recovery_token: token,
              recovery_sent_at: new Date().toISOString(),
            }
          }
        );

        if (updateError) throw new Error(`Error al guardar token: ${updateError.message}`);

        // Encolar correo de recuperación en el Core
        try {
          const coreSupabase = getCoreSupabaseClient();
          await coreSupabase.rpc('queue_password_reset_email', {
            p_email: email,
            p_token: token,
            p_platform_id: platform_id,
            p_tenant_id: user.app_metadata?.assignments?.[0]?.tenant_id || null,
          });
        } catch (coreError) {
          console.error('Error al encolar email de recuperación en Core:', coreError);
          // No bloqueamos el flujo — el token ya fue guardado
        }

        responseData = {
          success: true,
          message: 'Si tu correo está registrado, recibirás un enlace para restablecer tu contraseña.',
        };
        break;
      }

      // -----------------------------------------------------------------------
      // SET PASSWORD WITH TOKEN — Establece nueva contraseña con token
      // -----------------------------------------------------------------------
      case 'set-password-with-token': {
        console.log('Iniciando acción: set-password-with-token');
        const { token, newPassword } = payload;
        if (!token || !newPassword) throw new Error('El token y la nueva contraseña son obligatorios.');

        const { data: users, error: rpcError } = await supabaseAdmin.rpc(
          'get_user_by_recovery_token',
          { p_token: token }
        );
        if (rpcError) throw rpcError;
        if (!users || users.length === 0) throw new Error('Token inválido, expirado o no encontrado.');

        const user = users[0];
        const { data: updatedUser, error: updateError } = await supabaseAdmin.auth.admin.updateUserById(
          user.id,
          { password: newPassword }
        );
        if (updateError) throw updateError;

        // Limpiar el token de recuperación
        const cleanMetadata = { ...user.user_metadata };
        delete cleanMetadata.recovery_token;
        delete cleanMetadata.recovery_sent_at;
        await supabaseAdmin.auth.admin.updateUserById(user.id, { user_metadata: cleanMetadata });

        responseData = {
          success: true,
          message: 'Contraseña actualizada exitosamente.',
          userId: updatedUser.user.id,
        };
        break;
      }

      // -----------------------------------------------------------------------
      default:
        console.error('Acción no válida:', action);
        throw new Error(`La acción '${action}' no es válida en user-actions [NexuHR].`);
    }

    console.log('Respuesta exitosa enviada.');
    return new Response(JSON.stringify(responseData), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200,
    });

  } catch (error: any) {
    console.error('--- ERROR EN user-actions [NexuHR] ---');
    console.error('Error:', error.message);
    return new Response(
      JSON.stringify({ success: false, message: error.message }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 200, // Siempre 200 — el cliente maneja el error por el flag success
      }
    );
  }
});
