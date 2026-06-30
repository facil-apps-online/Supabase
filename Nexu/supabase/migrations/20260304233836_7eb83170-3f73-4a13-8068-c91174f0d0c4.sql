
-- Create evidences table
CREATE TABLE public.evidences (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES public.tenants(id),
    module text NOT NULL,
    record_id uuid NOT NULL,
    employee_id uuid REFERENCES public.employees(id),
    file_url text NOT NULL,
    file_name text NOT NULL,
    file_type text,
    file_size integer,
    description text,
    uploaded_by uuid,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);

-- Enable RLS
ALTER TABLE public.evidences ENABLE ROW LEVEL SECURITY;

-- RLS policies
CREATE POLICY "View evidences" ON public.evidences
    FOR SELECT TO authenticated
    USING (
        (tenant_id = get_user_tenant_id(auth.uid()))
        AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), module, 'ver'::permission_action))
    );

CREATE POLICY "Create evidences" ON public.evidences
    FOR INSERT TO authenticated
    WITH CHECK (
        (tenant_id = get_user_tenant_id(auth.uid()))
        AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), module, 'crear'::permission_action))
    );

CREATE POLICY "Delete evidences" ON public.evidences
    FOR DELETE TO authenticated
    USING (
        (tenant_id = get_user_tenant_id(auth.uid()))
        AND (is_super_admin(auth.uid()) OR has_permission(auth.uid(), module, 'eliminar'::permission_action))
    );

-- Updated_at trigger
CREATE TRIGGER update_evidences_updated_at
    BEFORE UPDATE ON public.evidences
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- Create storage bucket for evidences
INSERT INTO storage.buckets (id, name, public) VALUES ('evidences', 'evidences', false);

-- Storage RLS policies
CREATE POLICY "Authenticated users can upload evidences"
    ON storage.objects FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'evidences');

CREATE POLICY "Authenticated users can view evidences"
    ON storage.objects FOR SELECT TO authenticated
    USING (bucket_id = 'evidences');

CREATE POLICY "Authenticated users can delete evidences"
    ON storage.objects FOR DELETE TO authenticated
    USING (bucket_id = 'evidences');
