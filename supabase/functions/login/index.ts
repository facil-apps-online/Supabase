import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.43.2'
import { SignJWT } from "https://deno.land/x/jose@v5.2.3/index.ts";

Deno.serve(async (req) => {
  // Handle CORS preflight requests
  if (req.method === 'OPTIONS') {
    return new Response('ok', {
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
      },
    });
  }

  const corsHeaders = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  };

  if (req.method !== 'POST') {
    return new Response(JSON.stringify({ error: 'Method Not Allowed' }), {
      status: 405,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  try {
    const { email, password } = await req.json();

    if (!email || !password) {
      return new Response(JSON.stringify({ error: 'Email and password are required' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
      {
        auth: {
          persistSession: false,
        },
      }
    );

    // 1. Find the user by email
    const { data: users, error: userError } = await supabaseClient
      .from('users')
      .select('id, password_hash, role_id, tenant_id, branch_id')
      .eq('email', email)
      .single();

    if (userError || !users) {
      console.error('User not found or database error:', userError);
      return new Response(JSON.stringify({ error: 'Invalid credentials' }), {
        status: 401,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // 2. Verify the password by invoking the 'hash-password' function
    const { data: verifyData, error: verifyError } = await supabaseClient.functions.invoke('hash-password/verify', {
      body: { password, hash: users.password_hash },
    });

    if (verifyError || !verifyData.match) {
        return new Response(JSON.stringify({ error: 'Invalid credentials' }), {
            status: 401,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
    }

    // 3. Fetch role name
    const { data: role, error: roleError } = await supabaseClient
      .from('roles')
      .select('name')
      .eq('id', users.role_id)
      .single();

    if (roleError || !role) {
      console.error('Role not found or database error:', roleError);
      return new Response(JSON.stringify({ error: 'Internal server error: Role not found' }), {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // 4. Generate JWT
    const JWT_SECRET = Deno.env.get('JWT_SECRET');
    if (!JWT_SECRET) {
      return new Response(JSON.stringify({ error: 'Server configuration error: JWT_SECRET not set' }), {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    const secret = new TextEncoder().encode(JWT_SECRET);

    const jwt = await new SignJWT({
        sub: users.id,
        email: email,
        role: role.name,
        tenant_id: users.tenant_id,
        branch_id: users.branch_id,
      })
        .setProtectedHeader({ alg: "HS256" })
        .setIssuedAt()
        .setExpirationTime("1h")
        .sign(secret);

    return new Response(
      JSON.stringify({ jwt }),
      {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      },
    );
  } catch (error) {
    console.error('Error during login:', error);
    return new Response(JSON.stringify({ error: 'Internal server error' }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});