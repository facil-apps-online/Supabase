-- Migration: 20251217000001_create_absence_types_and_refactor_user_time_off.sql

-- Create absence_types table
CREATE TABLE public.absence_types (
  id UUID NOT NULL DEFAULT gen_random_uuid(),
  tenant_id UUID NOT NULL,
  name TEXT NOT NULL,
  description TEXT NULL,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMP WITH TIME ZONE NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NULL DEFAULT now(),
  CONSTRAINT absence_types_pkey PRIMARY KEY (id),
  CONSTRAINT absence_types_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants (id),
  CONSTRAINT absence_types_tenant_id_name_unique UNIQUE (tenant_id, name)
) TABLESPACE pg_default;

-- Add audit trigger for absence_types
CREATE TRIGGER audit_absence_types_changes
AFTER INSERT OR DELETE OR UPDATE ON public.absence_types
FOR EACH ROW EXECUTE FUNCTION audit_trigger_function();

-- Add updated_at trigger for absence_types
CREATE TRIGGER trigger_absence_types_updated_at
BEFORE UPDATE ON public.absence_types
FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();


-- Migrate existing 'type' values to new absence_types
-- First, insert distinct existing types into absence_types for each tenant
INSERT INTO public.absence_types (tenant_id, name, description, is_active)
SELECT DISTINCT uto.tenant_id, uto.type, 'Tipo de ausencia migrado automáticamente', TRUE
FROM public.user_time_off AS uto
WHERE uto.type IS NOT NULL
ON CONFLICT (tenant_id, name) DO NOTHING;

-- Add new column absence_type_id to user_time_off
ALTER TABLE public.user_time_off
ADD COLUMN absence_type_id UUID;

-- Update the new column with corresponding absence_type_id
UPDATE public.user_time_off AS uto
SET absence_type_id = (
    SELECT at.id
    FROM public.absence_types AS at
    WHERE at.tenant_id = uto.tenant_id AND at.name = uto.type
);

-- Make absence_type_id NOT NULL
ALTER TABLE public.user_time_off
ALTER COLUMN absence_type_id SET NOT NULL;

-- Add foreign key constraint
ALTER TABLE public.user_time_off
ADD CONSTRAINT user_time_off_absence_type_id_fkey
FOREIGN KEY (absence_type_id) REFERENCES public.absence_types (id);

-- Drop the old type column
ALTER TABLE public.user_time_off
DROP COLUMN type;

-- Drop the old check constraint related to 'type' column
ALTER TABLE public.user_time_off
DROP CONSTRAINT IF EXISTS stylist_time_off_type_check;

-- Recreate idx_user_time_off_filters index without 'type'
-- Drop the old index
DROP INDEX IF EXISTS public.idx_user_time_off_filters;

-- Create the new index
CREATE INDEX IF NOT EXISTS idx_user_time_off_filters ON public.user_time_off USING btree (
  tenant_id,
  user_id,
  branch_id,
  status,
  absence_type_id, -- Use the new column
  created_at
) TABLESPACE pg_default;