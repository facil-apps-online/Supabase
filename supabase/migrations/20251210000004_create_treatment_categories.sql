CREATE TABLE public.treatment_categories (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL,
    name character varying NOT NULL,
    description text,
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    updated_at timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT treatment_categories_pkey PRIMARY KEY (id),
    CONSTRAINT treatment_categories_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE,
    CONSTRAINT treatment_categories_name_tenant_id_key UNIQUE (name, tenant_id)
);

-- Enable RLS
ALTER TABLE public.treatment_categories ENABLE ROW LEVEL SECURITY;

-- Create policy for users to read categories of their own tenant
CREATE POLICY "Allow read access to own tenant categories"
ON public.treatment_categories
FOR SELECT
USING (auth.uid() IN (
    SELECT user_id FROM public.user_assignments WHERE tenant_id = public.treatment_categories.tenant_id
));

-- Create policy for admins/super-admins to manage categories of their own tenant
CREATE POLICY "Allow full access for tenant admins"
ON public.treatment_categories
FOR ALL
USING (auth.uid() IN (
    SELECT ua.user_id
    FROM public.user_assignments ua
    JOIN public.roles r ON ua.role_id = r.id
    WHERE ua.tenant_id = public.treatment_categories.tenant_id
      AND (r.name = 'tenant_admin' OR r.name = 'tenant_super_admin')
))
WITH CHECK (auth.uid() IN (
    SELECT ua.user_id
    FROM public.user_assignments ua
    JOIN public.roles r ON ua.role_id = r.id
    WHERE ua.tenant_id = public.treatment_categories.tenant_id
      AND (r.name = 'tenant_admin' OR r.name = 'tenant_super_admin')
));
