-- Create exam_types table for standard and custom exam types
CREATE TABLE public.exam_types (
    id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT,
    active BOOLEAN DEFAULT true,
    is_standard BOOLEAN DEFAULT false,
    tenant_id UUID REFERENCES public.tenants(id) ON DELETE CASCADE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    -- Ensure standard types have no tenant_id and custom types have tenant_id
    CONSTRAINT exam_types_standard_or_tenant CHECK (
        (is_standard = true AND tenant_id IS NULL) OR 
        (is_standard = false AND tenant_id IS NOT NULL)
    )
);

-- Enable RLS
ALTER TABLE public.exam_types ENABLE ROW LEVEL SECURITY;

-- Policy: Everyone can view standard types (is_standard = true)
CREATE POLICY "Everyone can view standard exam types"
ON public.exam_types
FOR SELECT
USING (is_standard = true);

-- Policy: Users can view their tenant's custom types
CREATE POLICY "Users can view tenant exam types"
ON public.exam_types
FOR SELECT
USING (tenant_id = get_user_tenant_id(auth.uid()));

-- Policy: Users can create custom types for their tenant (not standard)
CREATE POLICY "Users can create tenant exam types"
ON public.exam_types
FOR INSERT
WITH CHECK (
    tenant_id = get_user_tenant_id(auth.uid()) 
    AND is_standard = false
);

-- Policy: Users can update their tenant's custom types (not standard)
CREATE POLICY "Users can update tenant exam types"
ON public.exam_types
FOR UPDATE
USING (
    tenant_id = get_user_tenant_id(auth.uid()) 
    AND is_standard = false
);

-- Policy: Users can delete their tenant's custom types (not standard)
CREATE POLICY "Users can delete tenant exam types"
ON public.exam_types
FOR DELETE
USING (
    tenant_id = get_user_tenant_id(auth.uid()) 
    AND is_standard = false
);

-- Super admins can manage all (including standard types)
CREATE POLICY "Super admins can manage all exam types"
ON public.exam_types
FOR ALL
USING (is_super_admin(auth.uid()));

-- Insert standard exam types (visible to all tenants, cannot be deleted)
INSERT INTO public.exam_types (name, description, is_standard, tenant_id) VALUES
    ('Ingreso', 'Examen médico de ingreso para nuevos empleados', true, NULL),
    ('Periódico', 'Examen médico periódico de seguimiento', true, NULL),
    ('Retiro', 'Examen médico de retiro al finalizar la relación laboral', true, NULL),
    ('Reintegro', 'Examen médico de reintegro después de una incapacidad', true, NULL),
    ('Por cambio de puesto', 'Examen médico por cambio de puesto de trabajo', true, NULL);

-- Add updated_at trigger
CREATE TRIGGER update_exam_types_updated_at
BEFORE UPDATE ON public.exam_types
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();