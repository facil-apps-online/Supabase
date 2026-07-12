-- Allow portal employees to update their own portal account
-- (e.g. must_change_password) without requiring tenant admin privileges.

CREATE POLICY "Portal employees can update own account"
ON public.employee_portal_accounts FOR UPDATE TO authenticated
USING (user_id = auth.uid())
WITH CHECK (user_id = auth.uid());
