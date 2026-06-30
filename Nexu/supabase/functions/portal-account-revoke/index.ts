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
    const { employee_id, reason } = await req.json()
    if (!employee_id) {
      return new Response(JSON.stringify({ error: 'employee_id required' }), { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
    }

    const { data: profile } = await admin.from('profiles').select('tenant_id, is_super_admin').eq('user_id', userData.user.id).single()
    if (!profile) return new Response(JSON.stringify({ error: 'Forbidden' }), { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })

    const { data: account } = await admin.from('employee_portal_accounts').select('id, user_id, tenant_id').eq('employee_id', employee_id).single()
    if (!account) return new Response(JSON.stringify({ error: 'Cuenta no encontrada' }), { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
    if (!profile.is_super_admin && profile.tenant_id !== account.tenant_id) {
      return new Response(JSON.stringify({ error: 'Forbidden' }), { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
    }

    if (account.user_id) {
      await admin.auth.admin.deleteUser(account.user_id).catch((err) => console.warn('deleteUser warn', err))
    }
    await admin.from('employee_portal_accounts').update({
      status: 'revoked',
      revoked_at: new Date().toISOString(),
      revoked_reason: reason || 'Revocado por administrador',
      user_id: null,
    }).eq('id', account.id)

    return new Response(JSON.stringify({ ok: true, message: 'Acceso al portal revocado.' }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
  } catch (e: any) {
    console.error('portal-account-revoke error', e)
    return new Response(JSON.stringify({ error: e?.message || 'Internal error' }), { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
  }
})
