-- Drop existing broad policies and replace with permission-based policies

-- =====================
-- COURSES TABLE
-- =====================
DROP POLICY IF EXISTS "Tenant isolation for courses" ON public.courses;

CREATE POLICY "View courses" ON public.courses
FOR SELECT USING (
  tenant_id = get_user_tenant_id(auth.uid())
  AND (
    is_super_admin(auth.uid())
    OR has_permission(auth.uid(), 'cursos', 'ver')
  )
);

CREATE POLICY "Create courses" ON public.courses
FOR INSERT WITH CHECK (
  tenant_id = get_user_tenant_id(auth.uid())
  AND (
    is_super_admin(auth.uid())
    OR has_permission(auth.uid(), 'cursos', 'crear')
  )
);

CREATE POLICY "Update courses" ON public.courses
FOR UPDATE USING (
  tenant_id = get_user_tenant_id(auth.uid())
  AND (
    is_super_admin(auth.uid())
    OR has_permission(auth.uid(), 'cursos', 'editar')
  )
);

CREATE POLICY "Delete courses" ON public.courses
FOR DELETE USING (
  tenant_id = get_user_tenant_id(auth.uid())
  AND (
    is_super_admin(auth.uid())
    OR has_permission(auth.uid(), 'cursos', 'eliminar')
  )
);

-- =====================
-- VIGILANCIAS TABLE
-- =====================
DROP POLICY IF EXISTS "Tenant isolation for vigilancias" ON public.vigilancias;

CREATE POLICY "View vigilancias" ON public.vigilancias
FOR SELECT USING (
  tenant_id = get_user_tenant_id(auth.uid())
  AND (
    is_super_admin(auth.uid())
    OR has_permission(auth.uid(), 'vigilancias', 'ver')
  )
);

CREATE POLICY "Create vigilancias" ON public.vigilancias
FOR INSERT WITH CHECK (
  tenant_id = get_user_tenant_id(auth.uid())
  AND (
    is_super_admin(auth.uid())
    OR has_permission(auth.uid(), 'vigilancias', 'crear')
  )
);

CREATE POLICY "Update vigilancias" ON public.vigilancias
FOR UPDATE USING (
  tenant_id = get_user_tenant_id(auth.uid())
  AND (
    is_super_admin(auth.uid())
    OR has_permission(auth.uid(), 'vigilancias', 'editar')
  )
);

CREATE POLICY "Delete vigilancias" ON public.vigilancias
FOR DELETE USING (
  tenant_id = get_user_tenant_id(auth.uid())
  AND (
    is_super_admin(auth.uid())
    OR has_permission(auth.uid(), 'vigilancias', 'eliminar')
  )
);

-- =====================
-- DOTACION TABLE
-- =====================
DROP POLICY IF EXISTS "Tenant isolation for dotacion" ON public.dotacion;

CREATE POLICY "View dotacion" ON public.dotacion
FOR SELECT USING (
  tenant_id = get_user_tenant_id(auth.uid())
  AND (
    is_super_admin(auth.uid())
    OR has_permission(auth.uid(), 'dotacion', 'ver')
  )
);

CREATE POLICY "Create dotacion" ON public.dotacion
FOR INSERT WITH CHECK (
  tenant_id = get_user_tenant_id(auth.uid())
  AND (
    is_super_admin(auth.uid())
    OR has_permission(auth.uid(), 'dotacion', 'crear')
  )
);

CREATE POLICY "Update dotacion" ON public.dotacion
FOR UPDATE USING (
  tenant_id = get_user_tenant_id(auth.uid())
  AND (
    is_super_admin(auth.uid())
    OR has_permission(auth.uid(), 'dotacion', 'editar')
  )
);

CREATE POLICY "Delete dotacion" ON public.dotacion
FOR DELETE USING (
  tenant_id = get_user_tenant_id(auth.uid())
  AND (
    is_super_admin(auth.uid())
    OR has_permission(auth.uid(), 'dotacion', 'eliminar')
  )
);

-- =====================
-- COMMITTEES TABLE
-- =====================
DROP POLICY IF EXISTS "Tenant isolation for committees" ON public.committees;

CREATE POLICY "View committees" ON public.committees
FOR SELECT USING (
  tenant_id = get_user_tenant_id(auth.uid())
  AND (
    is_super_admin(auth.uid())
    OR has_permission(auth.uid(), 'comites', 'ver')
  )
);

CREATE POLICY "Create committees" ON public.committees
FOR INSERT WITH CHECK (
  tenant_id = get_user_tenant_id(auth.uid())
  AND (
    is_super_admin(auth.uid())
    OR has_permission(auth.uid(), 'comites', 'crear')
  )
);

CREATE POLICY "Update committees" ON public.committees
FOR UPDATE USING (
  tenant_id = get_user_tenant_id(auth.uid())
  AND (
    is_super_admin(auth.uid())
    OR has_permission(auth.uid(), 'comites', 'editar')
  )
);

CREATE POLICY "Delete committees" ON public.committees
FOR DELETE USING (
  tenant_id = get_user_tenant_id(auth.uid())
  AND (
    is_super_admin(auth.uid())
    OR has_permission(auth.uid(), 'comites', 'eliminar')
  )
);

-- =====================
-- PERFORMANCE_EVALUATIONS TABLE
-- =====================
DROP POLICY IF EXISTS "Tenant isolation for performance_evaluations" ON public.performance_evaluations;

CREATE POLICY "View performance_evaluations" ON public.performance_evaluations
FOR SELECT USING (
  tenant_id = get_user_tenant_id(auth.uid())
  AND (
    is_super_admin(auth.uid())
    OR has_permission(auth.uid(), 'evaluaciones', 'ver')
  )
);

CREATE POLICY "Create performance_evaluations" ON public.performance_evaluations
FOR INSERT WITH CHECK (
  tenant_id = get_user_tenant_id(auth.uid())
  AND (
    is_super_admin(auth.uid())
    OR has_permission(auth.uid(), 'evaluaciones', 'crear')
  )
);

CREATE POLICY "Update performance_evaluations" ON public.performance_evaluations
FOR UPDATE USING (
  tenant_id = get_user_tenant_id(auth.uid())
  AND (
    is_super_admin(auth.uid())
    OR has_permission(auth.uid(), 'evaluaciones', 'editar')
  )
);

CREATE POLICY "Delete performance_evaluations" ON public.performance_evaluations
FOR DELETE USING (
  tenant_id = get_user_tenant_id(auth.uid())
  AND (
    is_super_admin(auth.uid())
    OR has_permission(auth.uid(), 'evaluaciones', 'eliminar')
  )
);

-- =====================
-- COMPETENCY_EVALUATIONS TABLE
-- =====================
DROP POLICY IF EXISTS "Tenant isolation for competency_evaluations" ON public.competency_evaluations;

CREATE POLICY "View competency_evaluations" ON public.competency_evaluations
FOR SELECT USING (
  tenant_id = get_user_tenant_id(auth.uid())
  AND (
    is_super_admin(auth.uid())
    OR has_permission(auth.uid(), 'evaluaciones', 'ver')
  )
);

CREATE POLICY "Create competency_evaluations" ON public.competency_evaluations
FOR INSERT WITH CHECK (
  tenant_id = get_user_tenant_id(auth.uid())
  AND (
    is_super_admin(auth.uid())
    OR has_permission(auth.uid(), 'evaluaciones', 'crear')
  )
);

CREATE POLICY "Update competency_evaluations" ON public.competency_evaluations
FOR UPDATE USING (
  tenant_id = get_user_tenant_id(auth.uid())
  AND (
    is_super_admin(auth.uid())
    OR has_permission(auth.uid(), 'evaluaciones', 'editar')
  )
);

CREATE POLICY "Delete competency_evaluations" ON public.competency_evaluations
FOR DELETE USING (
  tenant_id = get_user_tenant_id(auth.uid())
  AND (
    is_super_admin(auth.uid())
    OR has_permission(auth.uid(), 'evaluaciones', 'eliminar')
  )
);

-- =====================
-- EXAMS TABLE (also had broad policy)
-- =====================
DROP POLICY IF EXISTS "Tenant isolation for exams" ON public.exams;

CREATE POLICY "View exams" ON public.exams
FOR SELECT USING (
  tenant_id = get_user_tenant_id(auth.uid())
  AND (
    is_super_admin(auth.uid())
    OR has_permission(auth.uid(), 'examenes', 'ver')
  )
);

CREATE POLICY "Create exams" ON public.exams
FOR INSERT WITH CHECK (
  tenant_id = get_user_tenant_id(auth.uid())
  AND (
    is_super_admin(auth.uid())
    OR has_permission(auth.uid(), 'examenes', 'crear')
  )
);

CREATE POLICY "Update exams" ON public.exams
FOR UPDATE USING (
  tenant_id = get_user_tenant_id(auth.uid())
  AND (
    is_super_admin(auth.uid())
    OR has_permission(auth.uid(), 'examenes', 'editar')
  )
);

CREATE POLICY "Delete exams" ON public.exams
FOR DELETE USING (
  tenant_id = get_user_tenant_id(auth.uid())
  AND (
    is_super_admin(auth.uid())
    OR has_permission(auth.uid(), 'examenes', 'eliminar')
  )
);

-- =====================
-- COMMUNICATIONS TABLE (also had broad policy)
-- =====================
DROP POLICY IF EXISTS "Tenant isolation for communications" ON public.communications;

CREATE POLICY "View communications" ON public.communications
FOR SELECT USING (
  tenant_id = get_user_tenant_id(auth.uid())
  AND (
    is_super_admin(auth.uid())
    OR has_permission(auth.uid(), 'comunicaciones', 'ver')
  )
);

CREATE POLICY "Create communications" ON public.communications
FOR INSERT WITH CHECK (
  tenant_id = get_user_tenant_id(auth.uid())
  AND (
    is_super_admin(auth.uid())
    OR has_permission(auth.uid(), 'comunicaciones', 'crear')
  )
);

CREATE POLICY "Update communications" ON public.communications
FOR UPDATE USING (
  tenant_id = get_user_tenant_id(auth.uid())
  AND (
    is_super_admin(auth.uid())
    OR has_permission(auth.uid(), 'comunicaciones', 'editar')
  )
);

CREATE POLICY "Delete communications" ON public.communications
FOR DELETE USING (
  tenant_id = get_user_tenant_id(auth.uid())
  AND (
    is_super_admin(auth.uid())
    OR has_permission(auth.uid(), 'comunicaciones', 'eliminar')
  )
);