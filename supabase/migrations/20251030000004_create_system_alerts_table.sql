DROP TABLE IF EXISTS public.system_alerts;

CREATE TABLE public.system_alerts (
    id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
    platform TEXT NOT NULL,
    type TEXT NOT NULL,
    message TEXT NOT NULL,
    details JSONB,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    is_resolved BOOLEAN DEFAULT FALSE,
    resolved_at TIMESTAMP WITH TIME ZONE,
    resolved_by UUID REFERENCES auth.users(id)
);

ALTER TABLE public.system_alerts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Public can view system_alerts" ON public.system_alerts FOR SELECT USING (true);
CREATE POLICY "Authenticated can insert system_alerts" ON public.system_alerts FOR INSERT WITH CHECK (auth.role() = 'authenticated');
CREATE POLICY "Superadmins can update system_alerts" ON public.system_alerts FOR UPDATE USING (auth.uid() IN (SELECT user_id FROM public.user_assignments WHERE role_id = (SELECT id FROM public.roles WHERE name = 'super_admin')));
