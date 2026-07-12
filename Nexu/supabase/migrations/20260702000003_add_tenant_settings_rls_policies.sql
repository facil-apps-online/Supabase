-- Add RLS policies for tenant_settings and tenant_social_networks

-- tenant_settings
CREATE POLICY "Super admins can manage all tenant_settings"
  ON public.tenant_settings FOR ALL
  USING (public.is_super_admin(auth.uid()));

CREATE POLICY "Tenant members can manage their own tenant_settings"
  ON public.tenant_settings FOR ALL
  USING (tenant_id = public.get_user_tenant_id(auth.uid()));

-- tenant_social_networks
CREATE POLICY "Super admins can manage all tenant_social_networks"
  ON public.tenant_social_networks FOR ALL
  USING (public.is_super_admin(auth.uid()));

CREATE POLICY "Tenant members can manage their own tenant_social_networks"
  ON public.tenant_social_networks FOR ALL
  USING (tenant_id = public.get_user_tenant_id(auth.uid()));
