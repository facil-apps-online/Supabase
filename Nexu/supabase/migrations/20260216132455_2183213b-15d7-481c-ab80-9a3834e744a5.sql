
-- Allow tenants to toggle active on standard exam_types
DROP POLICY IF EXISTS "Users can update tenant exam types" ON public.exam_types;
CREATE POLICY "Users can update exam types"
ON public.exam_types FOR UPDATE
USING (
  (tenant_id = get_user_tenant_id(auth.uid()) AND is_standard = false)
  OR (is_standard = true AND get_user_tenant_id(auth.uid()) IS NOT NULL)
);

-- Allow tenants to toggle active on standard vigilancia_types
DROP POLICY IF EXISTS "Users can update tenant vigilancia types" ON public.vigilancia_types;
CREATE POLICY "Users can update vigilancia types"
ON public.vigilancia_types FOR UPDATE
USING (
  (tenant_id = get_user_tenant_id(auth.uid()) AND is_standard = false)
  OR (is_standard = true AND get_user_tenant_id(auth.uid()) IS NOT NULL)
);

-- Allow tenants to toggle active on standard course_providers
DROP POLICY IF EXISTS "Users can update tenant course providers" ON public.course_providers;
CREATE POLICY "Users can update course providers"
ON public.course_providers FOR UPDATE
USING (
  (tenant_id = get_user_tenant_id(auth.uid()) AND is_standard = false)
  OR (is_standard = true AND get_user_tenant_id(auth.uid()) IS NOT NULL)
);

-- Allow tenants to toggle active on standard course_types
DROP POLICY IF EXISTS "Users can update tenant course types" ON public.course_types;
CREATE POLICY "Users can update course types"
ON public.course_types FOR UPDATE
USING (
  (tenant_id = get_user_tenant_id(auth.uid()) AND is_standard = false)
  OR (is_standard = true AND get_user_tenant_id(auth.uid()) IS NOT NULL)
);
