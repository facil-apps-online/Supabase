
-- ============================================
-- 1. TABLE: employee_portal_accounts
-- ============================================
CREATE TABLE public.employee_portal_accounts (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id uuid NOT NULL UNIQUE REFERENCES public.employees(id) ON DELETE CASCADE,
    tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
    user_id uuid,
    synthetic_email text NOT NULL UNIQUE,
    must_change_password boolean NOT NULL DEFAULT true,
    status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','revoked')),
    activated_at timestamptz NOT NULL DEFAULT now(),
    last_login_at timestamptz,
    revoked_at timestamptz,
    revoked_reason text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_epa_tenant ON public.employee_portal_accounts(tenant_id);
CREATE INDEX idx_epa_user ON public.employee_portal_accounts(user_id);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.employee_portal_accounts TO authenticated;
GRANT ALL ON public.employee_portal_accounts TO service_role;

ALTER TABLE public.employee_portal_accounts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Employee sees own portal account"
ON public.employee_portal_accounts FOR SELECT TO authenticated
USING (user_id = auth.uid());

CREATE POLICY "Tenant admins manage portal accounts"
ON public.employee_portal_accounts FOR ALL TO authenticated
USING (public.is_super_admin(auth.uid()) OR tenant_id = public.get_user_tenant_id(auth.uid()))
WITH CHECK (public.is_super_admin(auth.uid()) OR tenant_id = public.get_user_tenant_id(auth.uid()));

CREATE TRIGGER update_epa_updated_at
BEFORE UPDATE ON public.employee_portal_accounts
FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- ============================================
-- 2. get_current_employee_id
-- ============================================
CREATE OR REPLACE FUNCTION public.get_current_employee_id()
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT employee_id FROM public.employee_portal_accounts
    WHERE user_id = auth.uid() AND status = 'active' LIMIT 1
$$;
GRANT EXECUTE ON FUNCTION public.get_current_employee_id() TO authenticated;

-- ============================================
-- 3. resolve_employee_login
-- ============================================
CREATE OR REPLACE FUNCTION public.resolve_employee_login(
    p_documento text, p_tenant_slug text DEFAULT NULL
)
RETURNS TABLE(synthetic_email text, must_change_password boolean, tenant_slug text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
    RETURN QUERY
    SELECT epa.synthetic_email, epa.must_change_password, t.slug
    FROM public.employee_portal_accounts epa
    JOIN public.employees e ON e.id = epa.employee_id
    JOIN public.tenants t ON t.id = epa.tenant_id
    WHERE e.document_number = p_documento
      AND epa.status = 'active'
      AND (p_tenant_slug IS NULL OR t.slug = p_tenant_slug)
    LIMIT 1;
END;
$$;
GRANT EXECUTE ON FUNCTION public.resolve_employee_login(text, text) TO anon, authenticated;

-- ============================================
-- 4. auto-revoke on retire
-- ============================================
CREATE OR REPLACE FUNCTION public.revoke_portal_on_retire()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    IF (NEW.active = false OR NEW.termination_date IS NOT NULL)
       AND (OLD.active IS DISTINCT FROM NEW.active OR OLD.termination_date IS DISTINCT FROM NEW.termination_date) THEN
        UPDATE public.employee_portal_accounts
        SET status = 'revoked', revoked_at = now(),
            revoked_reason = COALESCE(revoked_reason, 'Retiro del empleado')
        WHERE employee_id = NEW.id AND status = 'active';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER employees_revoke_portal_on_retire
AFTER UPDATE ON public.employees
FOR EACH ROW EXECUTE FUNCTION public.revoke_portal_on_retire();

-- ============================================
-- 5. PORTAL RLS POLICIES (additive)
-- ============================================
CREATE POLICY "Employee portal: read own employee row"
ON public.employees FOR SELECT TO authenticated
USING (id = public.get_current_employee_id());

CREATE POLICY "Employee portal: update own employee row"
ON public.employees FOR UPDATE TO authenticated
USING (id = public.get_current_employee_id())
WITH CHECK (id = public.get_current_employee_id());

CREATE POLICY "Employee portal: read own payroll"
ON public.payroll_records FOR SELECT TO authenticated
USING (employee_id = public.get_current_employee_id());

CREATE POLICY "Employee portal: read own payroll items"
ON public.payroll_items FOR SELECT TO authenticated
USING (employee_id = public.get_current_employee_id());

CREATE POLICY "Employee portal: read regulations of own tenant"
ON public.regulations FOR SELECT TO authenticated
USING (tenant_id = (SELECT tenant_id FROM public.employees WHERE id = public.get_current_employee_id()));

CREATE POLICY "Employee portal: read own ack"
ON public.regulation_acknowledgments FOR SELECT TO authenticated
USING (employee_id = public.get_current_employee_id());

CREATE POLICY "Employee portal: create own ack"
ON public.regulation_acknowledgments FOR INSERT TO authenticated
WITH CHECK (employee_id = public.get_current_employee_id());

CREATE POLICY "Employee portal: update own ack"
ON public.regulation_acknowledgments FOR UPDATE TO authenticated
USING (employee_id = public.get_current_employee_id())
WITH CHECK (employee_id = public.get_current_employee_id());

CREATE POLICY "Employee portal: read own signatures"
ON public.signatures FOR SELECT TO authenticated
USING (employee_id = public.get_current_employee_id());

CREATE POLICY "Employee portal: create own signatures"
ON public.signatures FOR INSERT TO authenticated
WITH CHECK (employee_id = public.get_current_employee_id());

CREATE POLICY "Employee portal: read own evidences"
ON public.evidences FOR SELECT TO authenticated
USING (employee_id = public.get_current_employee_id());

CREATE POLICY "Employee portal: create own evidences"
ON public.evidences FOR INSERT TO authenticated
WITH CHECK (employee_id = public.get_current_employee_id());

CREATE POLICY "Employee portal: read own dotacion"
ON public.dotacion FOR SELECT TO authenticated
USING (employee_id = public.get_current_employee_id());

CREATE POLICY "Employee portal: sign own dotacion"
ON public.dotacion FOR UPDATE TO authenticated
USING (employee_id = public.get_current_employee_id())
WITH CHECK (employee_id = public.get_current_employee_id());

CREATE POLICY "Employee portal: read own exams"
ON public.exams FOR SELECT TO authenticated
USING (employee_id = public.get_current_employee_id());

CREATE POLICY "Employee portal: read own evaluations"
ON public.evaluations FOR SELECT TO authenticated
USING (employee_id = public.get_current_employee_id() OR evaluator_id = public.get_current_employee_id());

CREATE POLICY "Employee portal: respond evaluations"
ON public.evaluations FOR UPDATE TO authenticated
USING (employee_id = public.get_current_employee_id() OR evaluator_id = public.get_current_employee_id())
WITH CHECK (employee_id = public.get_current_employee_id() OR evaluator_id = public.get_current_employee_id());

CREATE POLICY "Employee portal: manage own evaluation responses"
ON public.evaluation_responses FOR ALL TO authenticated
USING (evaluation_id IN (SELECT id FROM public.evaluations
    WHERE employee_id = public.get_current_employee_id() OR evaluator_id = public.get_current_employee_id()))
WITH CHECK (evaluation_id IN (SELECT id FROM public.evaluations
    WHERE employee_id = public.get_current_employee_id() OR evaluator_id = public.get_current_employee_id()));

CREATE POLICY "Employee portal: read own courses"
ON public.courses FOR SELECT TO authenticated
USING (employee_id = public.get_current_employee_id());

CREATE POLICY "Employee portal: read own event participation"
ON public.event_participants FOR SELECT TO authenticated
USING (employee_id = public.get_current_employee_id());

CREATE POLICY "Employee portal: confirm own attendance"
ON public.event_participants FOR UPDATE TO authenticated
USING (employee_id = public.get_current_employee_id())
WITH CHECK (employee_id = public.get_current_employee_id());

CREATE POLICY "Employee portal: read assigned events"
ON public.events FOR SELECT TO authenticated
USING (id IN (SELECT event_id FROM public.event_participants
    WHERE employee_id = public.get_current_employee_id()));

CREATE POLICY "Employee portal: read tenant certificate templates"
ON public.certificate_templates FOR SELECT TO authenticated
USING (tenant_id = (SELECT tenant_id FROM public.employees WHERE id = public.get_current_employee_id()));

CREATE POLICY "Employee portal: read own vigilancias"
ON public.vigilancias FOR SELECT TO authenticated
USING (employee_id = public.get_current_employee_id());
