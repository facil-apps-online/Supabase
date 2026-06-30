-- Migration to add foreign keys for product_movements.

ALTER TABLE public.product_movements ADD CONSTRAINT product_movements_branch_id_fkey FOREIGN KEY (branch_id, platform_id, tenant_id) REFERENCES public.branches(id, platform_id, tenant_id) ON DELETE CASCADE;
ALTER TABLE public.product_movements ADD CONSTRAINT product_movements_product_id_fkey FOREIGN KEY (tenant_id, product_id, platform_id) REFERENCES public.products(tenant_id, id, platform_id) ON DELETE CASCADE;
