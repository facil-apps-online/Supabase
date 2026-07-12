-- Convert document_types to support is_standard pattern
-- Allows default types (CC, CE, TI, PA, NIT) available to all tenants
-- and custom types per tenant.

-- 1. Add is_standard column (nullable, default false)
ALTER TABLE public.document_types 
ADD COLUMN is_standard BOOLEAN DEFAULT false;

-- 2. Make tenant_id nullable
ALTER TABLE public.document_types 
ALTER COLUMN tenant_id DROP NOT NULL;

-- 3. Add CHECK constraint
ALTER TABLE public.document_types 
ADD CONSTRAINT document_types_standard_or_tenant CHECK (
  (is_standard = true AND tenant_id IS NULL) OR 
  (is_standard = false AND tenant_id IS NOT NULL)
);

-- 4. Drop old UNIQUE(tenant_id, code) and add new one
ALTER TABLE public.document_types 
DROP CONSTRAINT IF EXISTS document_types_tenant_id_code_key;

CREATE UNIQUE INDEX document_types_tenant_code_idx 
ON public.document_types (tenant_id, code) 
WHERE tenant_id IS NOT NULL;

CREATE UNIQUE INDEX document_types_standard_code_idx 
ON public.document_types (code) 
WHERE is_standard = true;

-- 5. Convert existing seeded types to standard
-- First, delete any duplicate seeded rows keeping one representative
DELETE FROM public.document_types a
USING public.document_types b
WHERE a.id <> b.id
  AND a.code IN ('CC', 'CE', 'TI', 'PA')
  AND a.code = b.code
  AND a.tenant_id IS NOT NULL
  AND b.tenant_id IS NOT NULL;

-- Update the remaining seeded rows to standard
UPDATE public.document_types
SET is_standard = true, tenant_id = NULL
WHERE code IN ('CC', 'CE', 'TI', 'PA') AND tenant_id IS NOT NULL;

-- 6. Insert NIT as a standard type if not exists
INSERT INTO public.document_types (code, name, is_standard, tenant_id, active)
SELECT 'NIT', 'Nit', true, NULL, true
WHERE NOT EXISTS (SELECT 1 FROM public.document_types WHERE code = 'NIT' AND is_standard = true);

-- 7. Update RLS policies
DROP POLICY IF EXISTS "Tenant isolation for document_types" ON public.document_types;

CREATE POLICY "Users can view document types"
ON public.document_types FOR SELECT
USING (
  is_standard = true
  OR tenant_id = get_user_tenant_id(auth.uid())
  OR is_super_admin(auth.uid())
);

CREATE POLICY "Users can insert document types"
ON public.document_types FOR INSERT
WITH CHECK (
  (tenant_id = get_user_tenant_id(auth.uid()) AND is_standard = false)
  OR is_super_admin(auth.uid())
);

CREATE POLICY "Users can update document types"
ON public.document_types FOR UPDATE
USING (
  (tenant_id = get_user_tenant_id(auth.uid()) AND is_standard = false)
  OR (is_standard = true AND get_user_tenant_id(auth.uid()) IS NOT NULL)
  OR is_super_admin(auth.uid())
);

CREATE POLICY "Users can delete document types"
ON public.document_types FOR DELETE
USING (
  (tenant_id = get_user_tenant_id(auth.uid()) AND is_standard = false)
  OR is_super_admin(auth.uid())
);
