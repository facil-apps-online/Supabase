-- RPC for portal employees to mark their password as changed
-- Bypasses RLS since portal users don't have UPDATE permission on employee_portal_accounts

CREATE OR REPLACE FUNCTION public.portal_account_mark_password_changed(p_account_id UUID)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    UPDATE public.employee_portal_accounts
    SET must_change_password = false
    WHERE id = p_account_id AND user_id = auth.uid();
END;
$$;

GRANT EXECUTE ON FUNCTION public.portal_account_mark_password_changed(UUID) TO authenticated;
