-- Faltaban FK (perdidas en el refactor de constraints) que PostgREST necesita para los embeds:
-- get_sale_details (sales->clients/branches), facturas (invoices->attentions) y atenciones (attention_services->services).
ALTER TABLE public.sales ADD CONSTRAINT sales_client_id_fkey FOREIGN KEY (client_id, tenant_id, platform_id) REFERENCES public.clients(id, tenant_id, platform_id) NOT VALID;
ALTER TABLE public.sales ADD CONSTRAINT sales_branch_id_fkey FOREIGN KEY (branch_id, tenant_id, platform_id) REFERENCES public.branches(id, tenant_id, platform_id) NOT VALID;
ALTER TABLE public.invoices ADD CONSTRAINT invoices_attention_id_fkey FOREIGN KEY (attention_id, tenant_id, platform_id) REFERENCES public.attentions(id, tenant_id, platform_id) NOT VALID;
ALTER TABLE public.attention_services ADD CONSTRAINT attention_services_service_id_fkey FOREIGN KEY (service_id, tenant_id, platform_id) REFERENCES public.services(id, tenant_id, platform_id) NOT VALID;
ALTER TABLE public.sales VALIDATE CONSTRAINT sales_client_id_fkey;
ALTER TABLE public.sales VALIDATE CONSTRAINT sales_branch_id_fkey;
ALTER TABLE public.invoices VALIDATE CONSTRAINT invoices_attention_id_fkey;
ALTER TABLE public.attention_services VALIDATE CONSTRAINT attention_services_service_id_fkey;
