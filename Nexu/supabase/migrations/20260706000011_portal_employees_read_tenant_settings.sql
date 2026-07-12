-- Portal employees need to read tenant_settings (e.g., portal permissions)
-- Existing policy relies on get_user_tenant_id() which looks up profiles,
-- but portal employees don't have profiles entries.
CREATE POLICY "Portal employees can read tenant_settings"
  ON public.tenant_settings FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.employee_portal_accounts
      WHERE user_id = auth.uid()
        AND tenant_id = tenant_settings.tenant_id
        AND status = 'active'
    )
  );
