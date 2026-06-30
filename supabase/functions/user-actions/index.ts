// Definición de las cabeceras CORS directamente en este archivo
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
  console.log('--- Nueva Invocación a user-actions ---');
  console.log('Método:', req.method);

  if (req.method === 'OPTIONS') {
    console.log('Respondiendo a petición OPTIONS (CORS pre-flight)');
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const body = await req.json();
    const { action, payload } = body;
    console.log('Acción recibida:', action);
    console.log('Payload recibido:', payload);

    // Cliente estándar para operaciones que no requieren rol de servicio (como el login)
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? ''
    );

    // Cliente Admin para operaciones que requieren bypass de RLS
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );
    console.log('Clientes de Supabase creados.');

    let responseData: any;

    console.log(`[user-actions] Antes del switch - Acción: ${action}, Payload:`, payload);

    switch (action) {
            case 'login-tenant': {
        console.log('Iniciando acción: login-tenant');
        const { email, password, platform_id } = payload;
        if (!email || !password || !platform_id) {
          throw new Error('El email, la contraseña y el platform_id son obligatorios.');
        }

        const synthetic_email = `${platform_id}_${email}`;
        console.log(`Intentando iniciar sesión con email sintético: ${synthetic_email}`);

        const { data, error } = await supabase.auth.signInWithPassword({
          email: synthetic_email,
          password: password,
        });

        if (error) {
          console.error('Error detallado en signInWithPassword:', error);
          throw new Error(`Error de autenticación: ${error.message}`);
        }

        if (!data.session || !data.user) {
            throw new Error('Inicio de sesión fallido, no se recibió una sesión o usuario.');
        }
        
        // SIMPLIFICADO: Devolver solo la sesión y el usuario. El cliente se encargará
        // de llamar a 'get-active-assignments' para obtener los datos de la sesión.
        responseData = { success: true, session: data.session, user: data.user };
        break;
      }

      case 'confirm-user-email': {
        console.log('Iniciando acción: confirm-user-email');
        const { email, platform_id } = payload;
        if (!email || !platform_id) {
          throw new Error('El email y el platform_id son obligatorios para confirmar el email.');
        }

        const synthetic_email = `${platform_id}_${email}`;

        const { data: { users }, error: findError } = await supabaseAdmin.auth.admin.listUsers({ email: synthetic_email });
        if (findError) throw new Error(`Error al buscar usuario: ${findError.message}`);
        if (!users || users.length === 0) throw new Error('No se encontró un usuario con ese correo electrónico para esta plataforma.');
        
        const userToConfirm = users[0];

        const { data: updatedUser, error: updateError } = await supabaseAdmin.auth.admin.updateUserById(
          userToConfirm.id,
          { email_confirm: true }
        );

        if (updateError) throw new Error(`Error al confirmar el email del usuario: ${updateError.message}`);
        
        responseData = { success: true, message: 'Email de usuario confirmado exitosamente.', user: updatedUser.user };
        break;
      }

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



      case 'repair-user-assignments': {
        console.log('Iniciando acción: repair-user-assignments');
        const { userId, targetTenantId } = payload; // Add targetTenantId to payload
        if (!userId || !targetTenantId) { // Update validation
          throw new Error('El userId y targetTenantId son obligatorios para reparar las asignaciones.');
        }

        // 1. Obtener todos los datos maestros necesarios en paralelo
        const [
          { data: roles, error: rolesError },
          { data: tenants, error: tenantsError },
          { data: branches, error: branchesError }
        ] = await Promise.all([
          supabaseAdmin.from('roles').select('id, name'),
          supabaseAdmin.from('tenants').select('id, name'),
          supabaseAdmin.from('branches').select('id, name, tenant_id')
        ]);

        if (rolesError || tenantsError || branchesError) {
          console.error({ rolesError, tenantsError, branchesError });
          throw new Error('No se pudieron obtener los datos maestros para la reparación.');
        }

        // 2. Encontrar los IDs específicos que necesitamos para el targetTenantId
        const tenantSuperAdminRole = roles.find(r => r.name === 'tenant_super_admin');
        const tenantAdminRole = roles.find(r => r.name === 'tenant_admin');
        const tenantUserRole = roles.find(r => r.name === 'tenant_user');
        
        // Find branches specific to the targetTenantId
        const principalBranch = branches.find(b => b.name === 'Sucursal Principal' && b.tenant_id === targetTenantId);
        if (!principalBranch) throw new Error(`No se encontró la "Sucursal Principal" para el tenant ${targetTenantId}.`);
        
        const medellinBranch = branches.find(b => b.name === 'Medellín' && b.tenant_id === targetTenantId);
        if (!medellinBranch) throw new Error(`No se encontró la sucursal "Medellín" para el tenant ${targetTenantId}.`);

        if (!tenantSuperAdminRole || !tenantAdminRole || !tenantUserRole) {
          throw new Error('Uno o más roles requeridos no se encontraron en la base de datos.');
        }

        // 3. Construir el array de asignaciones corregido para el targetTenantId
        const correctAssignmentsForTargetTenant = [
          {
            assignment_id: crypto.randomUUID(),
            tenant_id: targetTenantId,
            role_id: tenantSuperAdminRole.id,
            branch_id: null,
            status: 'active',
          },
          {
            assignment_id: crypto.randomUUID(),
            tenant_id: targetTenantId,
            role_id: tenantAdminRole.id,
            branch_id: principalBranch.id,
            status: 'active',
          },
          {
            assignment_id: crypto.randomUUID(),
            tenant_id: targetTenantId,
            role_id: tenantUserRole.id,
            branch_id: medellinBranch.id,
            status: 'active',
          }
        ];

        console.log('Asignaciones corregidas construidas para el tenant objetivo:', correctAssignmentsForTargetTenant);

        // 4. Obtener el usuario y fusionar sus asignaciones
        const { data: { user: currentUser }, error: getUserError } = await supabaseAdmin.auth.admin.getUserById(userId);
        if (getUserError) throw new Error(`Error al obtener el usuario: ${getUserError.message}`);

        const currentAppMetadata = currentUser.app_metadata || {};
        const existingAssignments = currentAppMetadata.assignments || [];

        // Filter out existing assignments for the targetTenantId
        const assignmentsForOtherTenants = existingAssignments.filter(
          (assignment: any) => assignment.tenant_id !== targetTenantId
        );

        // Combine assignments from other tenants with the new corrected assignments for the targetTenant
        const finalAssignments = [...assignmentsForOtherTenants, ...correctAssignmentsForTargetTenant];

        const { data: updatedUserResponse, error: updateError } = await supabaseAdmin.auth.admin.updateUserById(
          userId,
          { app_metadata: { ...currentAppMetadata, assignments: finalAssignments } }
        );

        if (updateError) {
          throw new Error(`Error al actualizar los metadatos del usuario: ${updateError.message}`);
        }

        responseData = { success: true, message: 'Asignaciones de usuario reparadas exitosamente.', user: updatedUserResponse.user };
        break;
      }

      case 'confirm-user-email': {
        console.log('Iniciando acción: confirm-user-email');
        const { email, platform_id } = payload;
        if (!email || !platform_id) {
          throw new Error('El email y el platform_id son obligatorios para confirmar el email.');
        }

        const synthetic_email = `${platform_id}_${email}`;

        // Buscar al usuario por el email sintético
        const { data: { users }, error: findError } = await supabaseAdmin.auth.admin.listUsers({ email: synthetic_email });
        if (findError) throw new Error(`Error al buscar usuario: ${findError.message}`);
        if (!users || users.length === 0) throw new Error('No se encontró un usuario con ese correo electrónico para esta plataforma.');
        
        const userToConfirm = users[0];

        // Confirmar el email del usuario
        const { data: updatedUser, error: updateError } = await supabaseAdmin.auth.admin.updateUserById(
          userToConfirm.id,
          { email_confirm: true } // Marca el email como confirmado
        );

        if (updateError) throw new Error(`Error al confirmar el email del usuario: ${updateError.message}`);
        
        responseData = { success: true, message: 'Email de usuario confirmado exitosamente.', user: updatedUser.user };
        break;
      }

      case 'switch-assignment': {
        console.log('Iniciando acción: switch-assignment');
        const { userId, newAssignmentId } = payload;
        if (!userId || !newAssignmentId) {
          throw new Error('El userId y el newAssignmentId son obligatorios.');
        }

        // Verificar que la asignación le pertenece al usuario en la tabla correcta.
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

        // Si la verificación es exitosa, no necesitamos hacer nada más.
        // El cliente ya actualizó el estado localmente.
        responseData = { success: true, message: 'Asignación verificada exitosamente.' };
        break;
      }

      case 'update-user-settings': {
        console.log('Iniciando acción: update-user-settings');
        const { userId, metadata } = payload;
        if (!userId || !metadata) {
          throw new Error('El userId y los metadatos son obligatorios.');
        }

        const { data: { user: currentUser }, error: getUserError } = await supabaseAdmin.auth.admin.getUserById(userId);
        if (getUserError) throw new Error(`Error de Supabase al obtener usuario: ${getUserError.message}`);

        let oldAvatarFileId: string | null = null;
        if (metadata.avatar_url !== undefined && currentUser.user_metadata?.avatar_url) {
          oldAvatarFileId = currentUser.user_metadata.avatar_url;
        }

        const updatedUserMetadata = {
          ...currentUser.user_metadata,
          ...metadata,
        };

        const { data: updatedUserResponse, error: updateError } = await supabaseAdmin.auth.admin.updateUserById(
          userId,
          { user_metadata: updatedUserMetadata }
        );

        if (updateError) {
          console.error('Error al actualizar user_metadata:', updateError.message);
          throw new Error(`Error al actualizar metadatos del usuario: ${updateError.message}`);
        }

        responseData = { 
          success: true, 
          message: 'Configuración de usuario actualizada.', 
          user: updatedUserResponse.user,
          oldAvatarFileId: oldAvatarFileId
        };
        break;
      }

      case 'get-user-metadata': {
        console.log('Iniciando acción: get-user-metadata');
        const { userId } = payload;
        if (!userId) {
          throw new Error('User ID is required.');
        }

        const { data: user, error: userError } = await supabaseAdmin.auth.admin.getUserById(userId);

        if (userError) {
          console.error('Error fetching user by ID:', userError.message);
          throw new Error(userError.message);
        }

        console.log('get-user-metadata: full user object', user);
        console.log('get-user-metadata: user.app_metadata', user?.app_metadata);
        responseData = { success: true, metadata: user?.app_metadata };
        break;
      }

      case 'update-password': {
        console.log('Iniciando acción: update-password');
        const { userId, newPassword } = payload;
        if (!userId || !newPassword) {
          throw new Error('El userId y la nueva contraseña son obligatorios.');
        }

        const { data: updatedUser, error: updateError } = await supabaseAdmin.auth.admin.updateUserById(
          userId,
          { password: newPassword }
        );

        if (updateError) throw new Error(`Error de Supabase al actualizar la contraseña: ${updateError.message}`);
        
        responseData = { success: true, message: 'Contraseña actualizada exitosamente.' };
        break;
      }
      
      case 'generate-recovery-token': {
        console.log('Iniciando acción: generate-recovery-token');
        const { email, platform_id } = payload;
        if (!email || !platform_id) throw new Error('El email y el platform_id son obligatorios.');

        const synthetic_email = `${platform_id}_${email}`;

        const { data: { users }, error: findError } = await supabaseAdmin.auth.admin.listUsers({ email: synthetic_email });
        if (findError) throw new Error(`Error de Supabase al buscar usuario: ${findError.message}`);
        if (!users || users.length === 0) throw new Error('No se encontró un usuario con ese correo electrónico.');
        
        const user = users[0];
        const token = crypto.randomUUID();

        const { error: updateError } = await supabaseAdmin.auth.admin.updateUserById(
          user.id,
          { user_metadata: { ...user.user_metadata, recovery_token: token, recovery_sent_at: new Date().toISOString() } })

        if (updateError) throw new Error(`Error de Supabase al actualizar usuario: ${updateError.message}`);
        
        // --- NUEVO: Encolar correo en Core ---
        const coreSupabase = getCoreSupabaseClient();
        const { data: rpcData, error: rpcError } = await coreSupabase.rpc('queue_password_reset_email', {
          p_email: email,
          p_token: token,
          p_platform_id: platform_id,
          p_tenant_id: user.app_metadata?.assignments?.[0]?.tenant_id // Asumimos que el primer tenant es válido para la plantilla
        });

        if (rpcError) {
            console.error(`Error al encolar email de reseteo: ${rpcError.message}`);
            // No bloqueamos al usuario, pero es un error importante a registrar.
        }
        if (rpcData && !rpcData.success) {
            console.error(`La RPC de encolado de email falló: ${rpcData.error}`);
        }

        responseData = { success: true, message: 'Si tu correo está registrado, recibirás un enlace para restablecer tu contraseña.' };
        break;
      }

      case 'set-password-with-token': {
        console.log('Iniciando acción: set-password-with-token');
        const { token, newPassword } = payload;
        if (!token || !newPassword) throw new Error('El token y la nueva contraseña son obligatorios.');

        const { data: users, error: rpcError } = await supabaseAdmin.rpc('get_user_by_recovery_token', { p_token: token });
        if (rpcError) throw rpcError;
        if (!users || users.length === 0) throw new Error('Token inválido, expirado o no encontrado.');
        
        const user = users[0];
        const { data: updatedUser, error: updateUserError } = await supabaseAdmin.auth.admin.updateUserById(user.id, { password: newPassword });
        if (updateUserError) throw updateUserError;

        const updatedMetadata = { ...user.user_metadata };
        delete updatedMetadata.recovery_token;
        delete updatedMetadata.recovery_sent_at;

        await supabaseAdmin.auth.admin.updateUserById(user.id, { user_metadata: updatedMetadata });
        
        responseData = { success: true, message: 'Contraseña actualizada exitosamente.', userId: updatedUser.user.id };
        break;
      }

      case 'check_user_exists_in_auth': {
        console.log('Iniciando acción: check_user_exists_in_auth');
        const { email, platformId } = payload;

        console.log(`[check_user_exists_in_auth] Payload recibido - Email: ${email}, PlatformId: ${platformId}`);

        if (!email || !platformId) {
          throw new Error('El email y el platformId son obligatorios para verificar la existencia del usuario.');
        }

        const synthetic_email = `${platformId}_${email}`;

        console.log(`[check_user_exists_in_auth] Buscando existencia de usuario con email sintético: ${synthetic_email} usando RPC check_user_exists_in_auth_rpc`);
        const { data: exists, error: rpcError } = await supabaseAdmin.rpc('check_user_exists_in_auth_rpc', { p_email: synthetic_email });
        
        if (rpcError) {
          console.error(`[check_user_exists_in_auth] Error al llamar a la RPC check_user_exists_in_auth_rpc: ${rpcError.message}`);
          throw new Error(`Error al verificar la existencia del usuario: ${rpcError.message}`);
        }
        
        console.log(`[check_user_exists_in_auth] Resultado de la RPC (exists):`, exists);
        
        responseData = { success: true, exists: exists };
        break;
      }

      case 'invite_or_assign_user_to_tenant': {
        console.log('Iniciando acción: invite_or_assign_user_to_tenant');
        const { email, password, tenantId, roleName, branchName, platformId, firstName, lastName, tenantData } = payload;

        if (!email || !tenantId || !roleName || !platformId) {
          throw new Error('Los campos email, tenantId, roleName y platformId son obligatorios.');
        }

        // 1. Buscar o crear el usuario en auth.users (Responsabilidad de la Edge Function)
        const synthetic_email = `${platformId}_${email}`;
        let userToAssign;

        const { data: { users: allUsers }, error: findError } = await supabaseAdmin.auth.admin.listUsers();
        if (findError) throw new Error(`Error al obtener la lista de usuarios: ${findError.message}`);
        const strictlyFoundUser = allUsers.find(user => user.email === synthetic_email);

        if (strictlyFoundUser) {
          userToAssign = strictlyFoundUser;
          console.log(`[invite_or_assign_user_to_tenant] Usuario existente encontrado:`, userToAssign.id);
        } else {
          console.log(`[invite_or_assign_user_to_tenant] Creando nuevo usuario...`);
          const { data: authData, error: authError } = await supabaseAdmin.auth.admin.createUser({
            email: synthetic_email,
            password: password || crypto.randomUUID(),
            email_confirm: true,
            user_metadata: { real_email: email, first_name: firstName, last_name: lastName },
          });
          if (authError) throw new Error(`Error al crear el usuario: ${authError.message}`);
          if (!authData.user) throw new Error('La creación del usuario no devolvió un objeto de usuario.');
          userToAssign = authData.user;
          console.log(`[invite_or_assign_user_to_tenant] Nuevo usuario creado:`, userToAssign.id);
        }

        if (!userToAssign) throw new Error('No se pudo obtener el usuario para asignar.');

        // 2. Delegar TODA la lógica de base de datos a la RPC (Tenant, Sucursal, Asignación)
        console.log('Invocando RPC create_tenant_with_admin para manejar base de datos...');
        
        const { data: rpcResult, error: rpcError } = await supabaseAdmin.rpc('create_tenant_with_admin', {
            p_tenant_id: tenantId,
            p_user_id: userToAssign.id,
            p_platform_id: platformId,
            p_tenant_name: tenantData?.name || 'Nuevo Negocio',
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
            p_einvoicing_email: tenantData?.einvoicing_email || null,
            p_physical_address_line1: tenantData?.physical_address_line1 || null,
            p_physical_address_line2: tenantData?.physical_address_line2 || null,
            p_physical_city: tenantData?.physical_city || null,
            p_physical_state: tenantData?.physical_state || null,
            p_physical_postal_code: tenantData?.physical_postal_code || null,
            p_default_language_code: tenantData?.default_language_code || 'es'
        });

        if (rpcError) {
            console.error('Error en RPC create_tenant_with_admin:', rpcError);
            throw new Error(`Error en base de datos: ${rpcError.message}`);
        }

        responseData = { 
            success: true, 
            message: 'Usuario y Tenant procesados exitosamente.', 
            user: userToAssign,
            db_details: rpcResult 
        };
        break;
      }

      case 'update-assignments': {
        const { userId, tenantId, assignments } = payload;
        if (!userId || !tenantId || !assignments) {
          throw new Error('userId, tenantId y assignments son obligatorios.');
        }

        const { error } = await supabaseAdmin.rpc('update_user_assignments', {
          p_user_id: userId,
          p_tenant_id: tenantId,
          p_new_assignments: assignments
        });

        if (error) {
          console.error('Error calling update_user_assignments RPC:', error);
          throw new Error('Ocurrió un error al actualizar las asignaciones.');
        }

        responseData = { success: true, message: 'Asignaciones de usuario actualizadas.' };
        break;
      }

      case 'create_auth_user': {
        console.log('Iniciando acción pura: create_auth_user');
        const { email, password, platformId } = payload;

        if (!email || !password || !platformId) {
          throw new Error('El email, la contraseña y el platformId son obligatorios.');
        }

        const synthetic_email = `${platformId}_${email}`;

        const { data: authData, error: authError } = await supabaseAdmin.auth.admin.createUser({
          email: synthetic_email,
          password: password,
          email_confirm: true,
          user_metadata: {
            email: email, // Guardamos únicamente el email real.
          },
        });

        console.log(`[create_auth_user] authData:`, authData);
        console.log(`[create_auth_user] authError:`, authError);

        if (authError) {
          throw new Error(`Error al crear el usuario: ${authError.message}`);
        }

        if (!authData.user) {
          throw new Error('No se pudo obtener el objeto de usuario después de la creación.');
        }

        responseData = { success: true, message: 'Usuario de Auth creado exitosamente.', user: authData.user };
        break;
      }

      case 'get-active-assignments': {
        console.log('Iniciando acción: get-active-assignments');
        const { userId, platformId } = payload;
        if (!userId || !platformId) {
          throw new Error('El userId y el platformId son obligatorios.');
        }

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
          console.error('Error al obtener las asignaciones activas:', queryError.message);
          throw new Error(`Error al consultar las asignaciones: ${queryError.message}`);
        }

        const mappedAssignments = assignments.map((a: any) => ({
          assignment_id: a.assignment_id,
          tenant_id: a.tenant_id,
          tenant_name: a.tenants.name || 'N/A',
          platform_id: a.tenants.platform_id, // Corrected line
          role_id: a.role_id,
          role_name: a.roles.name || 'N/A',
          role_display_name: a.roles.display_name || 'N/A',
          branch_id: a.branch_id || null,
          branch_name: a.branches?.name || null,
          status: a.status,
        }));

        responseData = { success: true, assignments: mappedAssignments };
        break;
      }

      case 'refresh-user-metadata': {
        console.log('Iniciando acción: refresh-user-metadata');
        const { userId, platformId } = payload;
        if (!userId || !platformId) {
          throw new Error('El userId y el platformId son obligatorios.');
        }

        // 1. Obtener las asignaciones activas del usuario desde la fuente de verdad.
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
          console.error('Error al obtener las asignaciones activas para rehidratación:', queryError.message);
          throw new Error(`Error al consultar las asignaciones: ${queryError.message}`);
        }

        // 2. Mapear las asignaciones al formato esperado en el app_metadata.
        const mappedAssignments = assignments.map((a: any) => ({
          assignment_id: a.assignment_id,
          tenant_id: a.tenant_id,
          tenant_name: a.tenants.name || 'N/A',
          platform_id: a.tenants.platform_id, // Corrected line
          role_id: a.role_id,
          role_name: a.roles.name || 'N/A',
          role_display_name: a.roles.display_name || 'N/A',
          branch_id: a.branch_id || null,
          branch_name: a.branches?.name || null,
          status: a.status,
        }));

        // 3. Construir el objeto de metadatos final.
        const newAppMetadata = {
          assignments: mappedAssignments,
        };

        // 4. Actualizar el usuario en auth.users con los nuevos metadatos.
        const { data: updatedUser, error: updateUserError } = await supabaseAdmin.auth.admin.updateUserById(
          userId,
          { app_metadata: newAppMetadata }
        );

        if (updateUserError) {
          console.error('Error al actualizar los metadatos del usuario:', updateUserError.message);
          throw new Error(`Error al actualizar el usuario: ${updateUserError.message}`);
        }

        responseData = { success: true, message: 'Metadatos de usuario actualizados exitosamente.' };
        break;
      }

      default:
        console.error('Acción no válida:', action);
        throw new Error(`La acción '${action}' no es válida.`);
    }

    console.log('Enviando respuesta exitosa.');
    return new Response(JSON.stringify(responseData), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200,
    });

  } catch (error) {
    console.error('--- ERROR EN LA EDGE FUNCTION ---');
    console.error('Error:', error.message);
    // Always return 200 OK, but with success: false in the body.
    // The client will handle the error based on the 'success' flag.
    return new Response(JSON.stringify({
      success: false,
      message: error.message,
    }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200, 
    });
  }
});
