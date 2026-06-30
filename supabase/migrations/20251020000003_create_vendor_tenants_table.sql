
CREATE TABLE public.vendor_tenants (
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  tenant_id UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, tenant_id)
);

ALTER TABLE public.vendor_tenants ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Allow superadmin to manage vendor_tenants" ON public.vendor_tenants
  FOR ALL
  USING (is_super_admin());
