import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { corsHeaders } from '../_shared/cors.ts';

interface RequestBody {
  email: string;
  tenantId: string;
  firstName?: string;
  lastName?: string;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const { email, tenantId, firstName, lastName }: RequestBody = await req.json();

    if (!email || !tenantId) {
      throw new Error('El email y el ID del tenant son obligatorios.');
    }

    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    // 1. Buscar si el usuario ya existe
    const { data: existingUser, error: getUserError } = await supabaseAdmin.auth.admin.getUserByEmail(email);

    if (getUserError && getUserError.message !== 'User not found') {
      throw getUserError; // Lanzar error si es algo distinto a "no encontrado"
    }

    // --- CASO A: El usuario NO existe ---
    if (!existingUser || !existingUser.user) {
      const assignment = {
        assignment_id: crypto.randomUUID(),
        tenant_id: tenantId,
        role_id: null,
        branch_id: null,
        status: 'active',
      };

      const appMetadata = { assignments: [assignment] };
      const userMetadata = { first_name: firstName, last_name: lastName };

      const { data: newUser, error: createUserError } = await supabaseAdmin.auth.admin.createUser({
        email: email,
        app_metadata: appMetadata,
        user_metadata: userMetadata,
        email_confirm: true,
      });

      if (createUserError) throw createUserError;

      return new Response(JSON.stringify({
        success: true,
        message: 'Usuario nuevo creado y vinculado al tenant. Se ha enviado un correo de invitación.',
        user: newUser.user,
      }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 200,
      });
    }

    // --- CASO B: El usuario SÍ existe ---
    const user = existingUser.user;
    const currentAssignments = user.app_metadata?.assignments || [];

    const isAlreadyLinked = currentAssignments.some(a => a.tenant_id === tenantId);

    if (isAlreadyLinked) {
      throw new Error('Este usuario ya está vinculado a este tenant.');
    }

    const newAssignment = {
      assignment_id: crypto.randomUUID(),
      tenant_id: tenantId,
      role_id: null,
      branch_id: null,
      status: 'active',
    };

    const updatedAssignments = [...currentAssignments, newAssignment];
    const updatedAppMetadata = { ...user.app_metadata, assignments: updatedAssignments };

    const { data: updatedUser, error: updateUserError } = await supabaseAdmin.auth.admin.updateUserById(
      user.id,
      { app_metadata: updatedAppMetadata }
    );

    if (updateUserError) throw updateUserError;

    return new Response(JSON.stringify({
      success: true,
      message: 'Usuario existente vinculado a este tenant.',
      user: updatedUser.user,
    }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200,
    });

  } catch (error) {
    return new Response(JSON.stringify({
      success: false,
      message: error.message,
    }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 400, // Usar 400 para errores de cliente, 500 para servidor
    });
  }
});
