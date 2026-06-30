-- Drop existing policies
DROP POLICY IF EXISTS "Public can view system_alerts" ON public.system_alerts;
DROP POLICY IF EXISTS "Authenticated can insert system_alerts" ON public.system_alerts;
DROP POLICY IF EXISTS "Superadmins can update system_alerts" ON public.system_alerts;

-- New policy for SELECT: Only superadmins can view system_alerts
CREATE POLICY "Superadmins can view system_alerts" ON public.system_alerts FOR SELECT USING (
  auth.uid() IN (SELECT user_id FROM public.user_assignments WHERE role_id = (SELECT id FROM public.roles WHERE name = 'super_admin'))
);

-- New policy for INSERT: Authenticated users can insert system_alerts
CREATE POLICY "Authenticated can insert system_alerts" ON public.system_alerts FOR INSERT WITH CHECK (
  auth.role() = 'authenticated'
);

-- New policy for UPDATE: Only superadmins can update system_alerts
CREATE POLICY "Superadmins can update system_alerts" ON public.system_alerts FOR UPDATE USING (
  auth.uid() IN (SELECT user_id FROM public.user_assignments WHERE role_id = (SELECT id FROM public.roles WHERE name = 'super_admin'))
);
