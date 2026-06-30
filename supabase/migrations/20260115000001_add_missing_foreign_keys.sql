-- Migration to add missing foreign keys to various tables.

-- contact_types
ALTER TABLE public.contact_types ADD CONSTRAINT contact_types_tenant_id_fkey FOREIGN KEY (platform_id, tenant_id) REFERENCES public.tenants(platform_id, id) ON DELETE CASCADE;

-- document_types
ALTER TABLE public.document_types ADD CONSTRAINT document_types_tenant_id_fkey FOREIGN KEY (platform_id, tenant_id) REFERENCES public.tenants(platform_id, id) ON DELETE CASCADE;

-- product_brands
ALTER TABLE public.product_brands ADD CONSTRAINT product_brands_tenant_id_fkey FOREIGN KEY (platform_id, tenant_id) REFERENCES public.tenants(platform_id, id) ON DELETE CASCADE;

-- product_categories
ALTER TABLE public.product_categories ADD CONSTRAINT product_categories_tenant_id_fkey FOREIGN KEY (platform_id, tenant_id) REFERENCES public.tenants(platform_id, id) ON DELETE CASCADE;

-- product_movements
ALTER TABLE public.product_movements ADD CONSTRAINT product_movements_tenant_id_fkey FOREIGN KEY (platform_id, tenant_id) REFERENCES public.tenants(platform_id, id) ON DELETE CASCADE;

-- roles (no FKs from roles table itself to tenants based on common patterns)
ALTER TABLE public.product_user_commissions ADD CONSTRAINT product_user_commissions_tenant_id_fkey FOREIGN KEY (platform_id, tenant_id) REFERENCES public.tenants(platform_id, id) ON DELETE CASCADE;
ALTER TABLE public.product_user_commissions ADD CONSTRAINT product_user_commissions_product_id_fkey FOREIGN KEY (tenant_id, product_id, platform_id) REFERENCES public.products(tenant_id, id, platform_id) ON DELETE CASCADE;
ALTER TABLE public.product_user_commissions ADD CONSTRAINT product_user_commissions_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

-- roles (no FKs from roles table itself to tenants based on common patterns)

-- service_categories
ALTER TABLE public.service_categories ADD CONSTRAINT service_categories_tenant_id_fkey FOREIGN KEY (platform_id, tenant_id) REFERENCES public.tenants(platform_id, id) ON DELETE CASCADE;

-- service_sessions
ALTER TABLE public.service_sessions ADD CONSTRAINT service_sessions_tenant_id_fkey FOREIGN KEY (platform_id, tenant_id) REFERENCES public.tenants(platform_id, id) ON DELETE CASCADE;

-- tax_types
ALTER TABLE public.tax_types ADD CONSTRAINT tax_types_tenant_id_fkey FOREIGN KEY (platform_id, tenant_id) REFERENCES public.tenants(platform_id, id) ON DELETE CASCADE;