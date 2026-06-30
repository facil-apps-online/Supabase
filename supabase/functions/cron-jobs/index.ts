import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    // 1. Create Supabase client with service_role key
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
      { auth: { persistSession: false } }
    );

    // 2. Extract job name from request body
    const { job_name } = await req.json();

    console.log(`Executing cron job: ${job_name}`);

    // 3. Switch on job name
    switch (job_name) {
      case 'equipment-maintenance-notifications':
        await handleEquipmentMaintenanceNotifications(supabaseAdmin);
        break;
      // Add other cases for other cron jobs here
      default:
        console.warn(`Unknown job_name: ${job_name}`);
        break;
    }

    return new Response(JSON.stringify({ success: true, job: job_name }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200,
    });

  } catch (error) {
    console.error('Error in cron job execution:', error);
    return new Response(JSON.stringify({ error: error.message }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 500,
    });
  }
});

async function handleEquipmentMaintenanceNotifications(supabaseAdmin: any) {
  const { data: equipment, error } = await supabaseAdmin
    .from('equipment')
    .select('*')
    .filter('is_active', 'eq', true)
    .filter('maintenance_frequency', 'isnot', null)
    .filter('last_maintenance_date', 'isnot', null);

  if (error) {
    console.error('Error fetching equipment:', error);
    return;
  }

  const today = new Date();
  today.setHours(0, 0, 0, 0);

  for (const item of equipment) {
    const lastMaintenance = new Date(item.last_maintenance_date);
    const nextMaintenanceDate = new Date(lastMaintenance);

    const frequency = item.maintenance_frequency;
    const unit = item.maintenance_frequency_unit; // 'days', 'weeks', 'months', 'years'

    if (unit === 'days') {
      nextMaintenanceDate.setDate(lastMaintenance.getDate() + frequency);
    } else if (unit === 'weeks') {
      nextMaintenanceDate.setDate(lastMaintenance.getDate() + frequency * 7);
    } else if (unit === 'months') {
      nextMaintenanceDate.setMonth(lastMaintenance.getMonth() + frequency);
    } else if (unit === 'years') {
      nextMaintenanceDate.setFullYear(lastMaintenance.getFullYear() + frequency);
    } else {
      continue; // Skip if unit is not recognized
    }

    nextMaintenanceDate.setHours(0, 0, 0, 0);

    // Check if today is the maintenance day or if it has passed
    if (today >= nextMaintenanceDate) {
      console.log(`Equipment ${item.name} (ID: ${item.id}) requires maintenance.`);
      // TODO: Implement actual notification logic here
      // e.g., insert into a 'notifications' table
    }
  }

  console.log('Finished checking equipment maintenance notifications.');
}