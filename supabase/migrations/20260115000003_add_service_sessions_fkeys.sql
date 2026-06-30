-- Migration to add foreign keys for service_sessions.

ALTER TABLE public.service_sessions ADD CONSTRAINT service_sessions_branch_id_fkey FOREIGN KEY (branch_id, platform_id, tenant_id) REFERENCES public.branches(id, platform_id, tenant_id) ON DELETE CASCADE;
ALTER TABLE public.service_sessions ADD CONSTRAINT service_sessions_attention_service_id_fkey FOREIGN KEY (attention_service_id, tenant_id, platform_id) REFERENCES public.attention_services(id, tenant_id, platform_id) ON DELETE CASCADE;
