-- Create document_types table
CREATE TABLE public.document_types (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  tenant_id UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  code TEXT NOT NULL,
  name TEXT NOT NULL,
  active BOOLEAN DEFAULT true,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  UNIQUE(tenant_id, code)
);

-- Create positions table (cargos)
CREATE TABLE public.positions (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  tenant_id UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  description TEXT,
  active BOOLEAN DEFAULT true,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  UNIQUE(tenant_id, name)
);

-- Create departments table (áreas)
CREATE TABLE public.departments (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  tenant_id UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  description TEXT,
  active BOOLEAN DEFAULT true,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  UNIQUE(tenant_id, name)
);

-- Add supervisor_id and termination_date to employees
ALTER TABLE public.employees 
ADD COLUMN supervisor_id UUID REFERENCES public.employees(id) ON DELETE SET NULL,
ADD COLUMN termination_date DATE;

-- Enable RLS
ALTER TABLE public.document_types ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.positions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.departments ENABLE ROW LEVEL SECURITY;

-- RLS policies for document_types
CREATE POLICY "Tenant isolation for document_types" 
ON public.document_types 
FOR ALL 
USING ((tenant_id = get_user_tenant_id(auth.uid())) OR is_super_admin(auth.uid()));

-- RLS policies for positions
CREATE POLICY "Tenant isolation for positions" 
ON public.positions 
FOR ALL 
USING ((tenant_id = get_user_tenant_id(auth.uid())) OR is_super_admin(auth.uid()));

-- RLS policies for departments
CREATE POLICY "Tenant isolation for departments" 
ON public.departments 
FOR ALL 
USING ((tenant_id = get_user_tenant_id(auth.uid())) OR is_super_admin(auth.uid()));

-- Insert default document types for existing tenants
INSERT INTO public.document_types (tenant_id, code, name)
SELECT id, 'CC', 'Cédula de Ciudadanía' FROM public.tenants
UNION ALL
SELECT id, 'CE', 'Cédula de Extranjería' FROM public.tenants
UNION ALL
SELECT id, 'TI', 'Tarjeta de Identidad' FROM public.tenants
UNION ALL
SELECT id, 'PA', 'Pasaporte' FROM public.tenants;