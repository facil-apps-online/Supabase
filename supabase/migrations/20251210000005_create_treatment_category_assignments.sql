CREATE TABLE public.treatment_category_assignments (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    treatment_id uuid NOT NULL,
    category_id uuid NOT NULL,
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT treatment_category_assignments_pkey PRIMARY KEY (id),
    CONSTRAINT treatment_category_assignments_treatment_id_fkey FOREIGN KEY (treatment_id) REFERENCES public.treatments(id) ON DELETE CASCADE,
    CONSTRAINT treatment_category_assignments_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.treatment_categories(id) ON DELETE CASCADE,
    CONSTRAINT treatment_category_assignments_treatment_id_category_id_key UNIQUE (treatment_id, category_id)
);

-- Enable RLS
ALTER TABLE public.treatment_category_assignments ENABLE ROW LEVEL SECURITY;

-- Create policy for users to read assignments of their own tenant
-- This is checked via the tenant_id of the linked treatment
CREATE POLICY "Allow read access to own tenant assignments"
ON public.treatment_category_assignments
FOR SELECT
USING (
    EXISTS (
        SELECT 1
        FROM public.treatments t
        JOIN public.user_assignments ua ON t.tenant_id = ua.tenant_id
        WHERE t.id = public.treatment_category_assignments.treatment_id AND ua.user_id = auth.uid()
    )
);

-- Create policy for admins/super-admins to manage assignments of their own tenant
CREATE POLICY "Allow full access for tenant admins on assignments"
ON public.treatment_category_assignments
FOR ALL
USING (
    EXISTS (
        SELECT 1
        FROM public.treatments t
        JOIN public.user_assignments ua ON t.tenant_id = ua.tenant_id
        JOIN public.roles r ON ua.role_id = r.id
        WHERE t.id = public.treatment_category_assignments.treatment_id 
          AND ua.user_id = auth.uid()
          AND (r.name = 'tenant_admin' OR r.name = 'tenant_super_admin')
    )
)
WITH CHECK (
    EXISTS (
        SELECT 1
        FROM public.treatments t
        JOIN public.user_assignments ua ON t.tenant_id = ua.tenant_id
        JOIN public.roles r ON ua.role_id = r.id
        WHERE t.id = public.treatment_category_assignments.treatment_id 
          AND ua.user_id = auth.uid()
          AND (r.name = 'tenant_admin' OR r.name = 'tenant_super_admin')
    )
);
