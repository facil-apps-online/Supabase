-- 1. Create the junction table for the many-to-many relationship
CREATE TABLE public.product_category_assignments (
    product_id uuid NOT NULL,
    category_id uuid NOT NULL,
    tenant_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT product_category_assignments_pkey PRIMARY KEY (product_id, category_id),
    CONSTRAINT product_category_assignments_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE CASCADE,
    CONSTRAINT product_category_assignments_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.product_categories(id) ON DELETE CASCADE,
    CONSTRAINT product_category_assignments_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE
);

-- Add comments to the table and columns
COMMENT ON TABLE public.product_category_assignments IS 'Junction table to link products with multiple categories.';
COMMENT ON COLUMN public.product_category_assignments.product_id IS 'Foreign key to the products table.';
COMMENT ON COLUMN public.product_category_assignments.category_id IS 'Foreign key to the product_categories table.';
COMMENT ON COLUMN public.product_category_assignments.tenant_id IS 'The tenant to which this assignment belongs.';

-- Enable RLS
ALTER TABLE public.product_category_assignments ENABLE ROW LEVEL SECURITY;

-- Create policies for RLS
CREATE POLICY "Allow tenant members to manage assignments" ON public.product_category_assignments
FOR ALL
USING (
    EXISTS (
        SELECT 1
        FROM public.user_assignments ua
        WHERE ua.tenant_id = product_category_assignments.tenant_id
          AND ua.user_id = auth.uid()
    )
)
WITH CHECK (
    EXISTS (
        SELECT 1
        FROM public.user_assignments ua
        WHERE ua.tenant_id = product_category_assignments.tenant_id
          AND ua.user_id = auth.uid()
    )
);

-- 2. Data Migration: This script attempts to migrate existing text-based categories to the new structure.
-- It's provided as a best-effort and should be reviewed before execution in production.
-- It assumes that the names in the old 'category' column match the names in 'product_categories' case-insensitively.
DO $$
DECLARE
    old_category_column_exists boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
        AND table_name = 'products'
        AND column_name = 'category'
    ) INTO old_category_column_exists;

    IF old_category_column_exists THEN
        -- Temporarily disable triggers to avoid any side-effects if they exist
        ALTER TABLE public.product_category_assignments DISABLE TRIGGER USER;

        -- Perform the migration
        INSERT INTO public.product_category_assignments (product_id, category_id, tenant_id)
        SELECT p.id, pc.id, p.tenant_id
        FROM public.products p
        JOIN public.product_categories pc ON lower(p.category) = lower(pc.name) AND p.tenant_id = pc.tenant_id
        WHERE p.category IS NOT NULL AND p.category <> ''
        ON CONFLICT (product_id, category_id) DO NOTHING;

        -- Re-enable triggers
        ALTER TABLE public.product_category_assignments ENABLE TRIGGER USER;
    END IF;
END $$;


-- 3. Remove the old 'category' column from the products table
ALTER TABLE public.products
DROP COLUMN IF EXISTS category;
