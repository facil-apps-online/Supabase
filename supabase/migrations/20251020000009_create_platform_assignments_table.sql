CREATE TABLE public.platform_assignments (
  id UUID DEFAULT gen_random_uuid() NOT NULL,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  platform_id UUID NOT NULL REFERENCES public.platforms(id) ON DELETE CASCADE,
  role_id UUID NOT NULL REFERENCES public.roles(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (user_id, platform_id, role_id)
);

ALTER TABLE public.platform_assignments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Allow superadmin to manage platform_assignments" ON public.platform_assignments
  FOR ALL
  USING (is_super_admin());
