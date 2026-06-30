-- Migration to add foreign keys for roles.

ALTER TABLE public.roles ADD CONSTRAINT roles_tenant_id_fkey FOREIGN KEY (platform_id, tenant_id) REFERENCES public.tenants(platform_id, id) ON DELETE SET NULL;
