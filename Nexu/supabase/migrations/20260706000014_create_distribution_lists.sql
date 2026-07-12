-- =============================================
-- Migration: Create distribution lists tables
-- =============================================

CREATE TABLE IF NOT EXISTS public.distribution_lists (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    description TEXT,
    list_type TEXT NOT NULL DEFAULT 'personalizada',
    target_value TEXT,
    active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now(),
    CONSTRAINT distribution_lists_list_type_check CHECK (list_type IN ('general', 'cargo', 'departamento', 'personalizada'))
);

CREATE TABLE IF NOT EXISTS public.distribution_list_members (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    list_id UUID NOT NULL REFERENCES public.distribution_lists(id) ON DELETE CASCADE,
    employee_id UUID NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE(list_id, employee_id)
);

-- RLS para distribution_lists
ALTER TABLE public.distribution_lists ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Los usuarios pueden ver listas de su tenant"
    ON public.distribution_lists FOR SELECT
    USING (tenant_id = public.get_user_tenant_id(auth.uid()) OR public.is_super_admin(auth.uid()));

CREATE POLICY "Los usuarios pueden insertar listas de su tenant"
    ON public.distribution_lists FOR INSERT
    WITH CHECK (tenant_id = public.get_user_tenant_id(auth.uid()) OR public.is_super_admin(auth.uid()));

CREATE POLICY "Los usuarios pueden actualizar listas de su tenant"
    ON public.distribution_lists FOR UPDATE
    USING (tenant_id = public.get_user_tenant_id(auth.uid()) OR public.is_super_admin(auth.uid()));

CREATE POLICY "Los usuarios pueden eliminar listas de su tenant"
    ON public.distribution_lists FOR DELETE
    USING (tenant_id = public.get_user_tenant_id(auth.uid()) OR public.is_super_admin(auth.uid()));


-- RLS para distribution_list_members
ALTER TABLE public.distribution_list_members ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Los usuarios pueden ver miembros de listas de su tenant"
    ON public.distribution_list_members FOR SELECT
    USING (EXISTS (
        SELECT 1 FROM public.distribution_lists dl
        WHERE dl.id = public.distribution_list_members.list_id
          AND (dl.tenant_id = public.get_user_tenant_id(auth.uid()) OR public.is_super_admin(auth.uid()))
    ));

CREATE POLICY "Los usuarios pueden insertar miembros de listas de su tenant"
    ON public.distribution_list_members FOR INSERT
    WITH CHECK (EXISTS (
        SELECT 1 FROM public.distribution_lists dl
        WHERE dl.id = list_id
          AND (dl.tenant_id = public.get_user_tenant_id(auth.uid()) OR public.is_super_admin(auth.uid()))
    ));

CREATE POLICY "Los usuarios pueden actualizar miembros de listas de su tenant"
    ON public.distribution_list_members FOR UPDATE
    USING (EXISTS (
        SELECT 1 FROM public.distribution_lists dl
        WHERE dl.id = public.distribution_list_members.list_id
          AND (dl.tenant_id = public.get_user_tenant_id(auth.uid()) OR public.is_super_admin(auth.uid()))
    ));

CREATE POLICY "Los usuarios pueden eliminar miembros de listas de su tenant"
    ON public.distribution_list_members FOR DELETE
    USING (EXISTS (
        SELECT 1 FROM public.distribution_lists dl
        WHERE dl.id = public.distribution_list_members.list_id
          AND (dl.tenant_id = public.get_user_tenant_id(auth.uid()) OR public.is_super_admin(auth.uid()))
    ));
