-- Create vigilancia_types table for master data
CREATE TABLE public.vigilancia_types (
    id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT,
    active BOOLEAN DEFAULT true,
    tenant_id UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Enable RLS
ALTER TABLE public.vigilancia_types ENABLE ROW LEVEL SECURITY;

-- Create RLS policies
CREATE POLICY "Users can view vigilancia types from their tenant"
ON public.vigilancia_types
FOR SELECT
USING (tenant_id = (SELECT tenant_id FROM public.profiles WHERE user_id = auth.uid() LIMIT 1));

CREATE POLICY "Users can create vigilancia types in their tenant"
ON public.vigilancia_types
FOR INSERT
WITH CHECK (tenant_id = (SELECT tenant_id FROM public.profiles WHERE user_id = auth.uid() LIMIT 1));

CREATE POLICY "Users can update vigilancia types in their tenant"
ON public.vigilancia_types
FOR UPDATE
USING (tenant_id = (SELECT tenant_id FROM public.profiles WHERE user_id = auth.uid() LIMIT 1));

CREATE POLICY "Users can delete vigilancia types in their tenant"
ON public.vigilancia_types
FOR DELETE
USING (tenant_id = (SELECT tenant_id FROM public.profiles WHERE user_id = auth.uid() LIMIT 1));

-- Add trigger for updated_at
CREATE TRIGGER update_vigilancia_types_updated_at
BEFORE UPDATE ON public.vigilancia_types
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();