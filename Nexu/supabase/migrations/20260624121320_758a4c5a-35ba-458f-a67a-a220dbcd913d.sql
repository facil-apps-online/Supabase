
-- Portal: allow employees to read evaluation templates/sections/criteria of their tenant
CREATE POLICY "Employee portal: read tenant evaluation templates"
ON public.evaluation_templates FOR SELECT
USING (
  tenant_id = (SELECT tenant_id FROM public.employee_portal_accounts WHERE user_id = auth.uid() AND status = 'active' LIMIT 1)
);

CREATE POLICY "Employee portal: read template sections"
ON public.evaluation_template_sections FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM public.evaluation_templates t
    JOIN public.employee_portal_accounts epa ON epa.tenant_id = t.tenant_id
    WHERE t.id = evaluation_template_sections.template_id
      AND epa.user_id = auth.uid() AND epa.status = 'active'
  )
);

CREATE POLICY "Employee portal: read template criteria"
ON public.evaluation_template_criteria FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM public.evaluation_template_sections s
    JOIN public.evaluation_templates t ON t.id = s.template_id
    JOIN public.employee_portal_accounts epa ON epa.tenant_id = t.tenant_id
    WHERE s.id = evaluation_template_criteria.section_id
      AND epa.user_id = auth.uid() AND epa.status = 'active'
  )
);

-- Portal: allow employees to update limited fields on their own profile (handled in app code)
-- The "Employee portal: update own employee row" policy may already exist; add if missing
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='employees'
      AND policyname='Employee portal: update own profile'
  ) THEN
    CREATE POLICY "Employee portal: update own profile"
      ON public.employees FOR UPDATE
      USING (id = public.get_current_employee_id())
      WITH CHECK (id = public.get_current_employee_id());
  END IF;
END $$;

-- Storage: allow portal employees to read their own files in private buckets
-- exam-documents: object name pattern contains employee_id; we filter by joining exams table
CREATE POLICY "Portal read own exam documents"
ON storage.objects FOR SELECT
USING (
  bucket_id = 'exam-documents'
  AND EXISTS (
    SELECT 1 FROM public.exams e
    WHERE e.document_url = storage.objects.name
      AND e.employee_id = public.get_current_employee_id()
  )
);

CREATE POLICY "Portal read own signatures"
ON storage.objects FOR SELECT
USING (
  bucket_id = 'signatures'
  AND EXISTS (
    SELECT 1 FROM public.signatures s
    WHERE s.signature_url = storage.objects.name
      AND s.employee_id = public.get_current_employee_id()
  )
);

CREATE POLICY "Portal write signatures"
ON storage.objects FOR INSERT
WITH CHECK (
  bucket_id = 'signatures'
  AND public.get_current_employee_id() IS NOT NULL
);

CREATE POLICY "Portal read own evidences"
ON storage.objects FOR SELECT
USING (
  bucket_id = 'evidences'
  AND EXISTS (
    SELECT 1 FROM public.evidences ev
    WHERE ev.file_url = storage.objects.name
      AND ev.employee_id = public.get_current_employee_id()
  )
);

-- regulations bucket public reads (all employees of tenant)
CREATE POLICY "Portal read regulations"
ON storage.objects FOR SELECT
USING (
  bucket_id = 'regulations'
  AND public.get_current_employee_id() IS NOT NULL
);
