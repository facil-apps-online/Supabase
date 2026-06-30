import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: corsHeaders })

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

    const authHeader = req.headers.get('Authorization')
    if (!authHeader?.startsWith('Bearer ')) {
      return new Response(JSON.stringify({ error: 'Unauthorized' }), { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
    }

    const supabaseAuth = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: authHeader } } })
    const { data: userData, error: userErr } = await supabaseAuth.auth.getUser()
    if (userErr || !userData?.user) {
      return new Response(JSON.stringify({ error: 'Invalid token' }), { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
    }

    const admin = createClient(supabaseUrl, serviceKey)
    const { employee_id } = await req.json()
    if (!employee_id) {
      return new Response(JSON.stringify({ error: 'employee_id required' }), { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
    }

    // Validate caller permission (super admin or same tenant admin)
    const { data: profile } = await admin.from('profiles').select('tenant_id, is_super_admin').eq('user_id', userData.user.id).single()
    if (!profile) {
      return new Response(JSON.stringify({ error: 'Profile not found' }), { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
    }

    const { data: employee, error: empErr } = await admin.from('employees').select('id, tenant_id, document_number, first_name, last_name, email, active').eq('id', employee_id).single()
    if (empErr || !employee) {
      return new Response(JSON.stringify({ error: 'Employee not found' }), { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
    }
    if (!profile.is_super_admin && profile.tenant_id !== employee.tenant_id) {
      return new Response(JSON.stringify({ error: 'Forbidden' }), { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
    }
    if (!employee.active) {
      return new Response(JSON.stringify({ error: 'Empleado inactivo' }), { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
    }

    const { data: tenant } = await admin.from('tenants').select('slug').eq('id', employee.tenant_id).single()
    const slug = (tenant?.slug || 'tenant').replace(/[^a-z0-9-]/gi, '').toLowerCase()
    const syntheticEmail = `${employee.document_number}@portal.${slug}.nexurh.app`
    const password = employee.document_number

    // Check existing record
    const { data: existing } = await admin.from('employee_portal_accounts').select('*').eq('employee_id', employee_id).maybeSingle()

    let userId: string
    if (existing?.user_id) {
      // Reactivate: ensure auth user exists with reset password
      const { data: updated, error: updErr } = await admin.auth.admin.updateUserById(existing.user_id, { password, email_confirm: true })
      if (updErr || !updated.user) {
        // recreate
        const { data: created, error: createErr } = await admin.auth.admin.createUser({ email: syntheticEmail, password, email_confirm: true })
        if (createErr || !created.user) throw createErr || new Error('Could not create auth user')
        userId = created.user.id
      } else {
        userId = updated.user.id
      }
      await admin.from('employee_portal_accounts').update({
        user_id: userId, status: 'active', must_change_password: true,
        activated_at: new Date().toISOString(), revoked_at: null, revoked_reason: null,
      }).eq('id', existing.id)
    } else {
      const { data: created, error: createErr } = await admin.auth.admin.createUser({ email: syntheticEmail, password, email_confirm: true })
      if (createErr || !created.user) {
        return new Response(JSON.stringify({ error: createErr?.message || 'Could not create user' }), { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
      }
      userId = created.user.id
      const { error: insErr } = await admin.from('employee_portal_accounts').insert({
        employee_id, tenant_id: employee.tenant_id, user_id: userId,
        synthetic_email: syntheticEmail, must_change_password: true, status: 'active',
      })
      if (insErr) {
        await admin.auth.admin.deleteUser(userId)
        throw insErr
      }
    }

    return new Response(JSON.stringify({
      ok: true, username: employee.document_number, password,
      message: 'Cuenta de portal activada. El empleado deberá cambiar la clave al ingresar.'
    }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
  } catch (e: any) {
    console.error('portal-account-create error', e)
    return new Response(JSON.stringify({ error: e?.message || 'Internal error' }), { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
  }
})
