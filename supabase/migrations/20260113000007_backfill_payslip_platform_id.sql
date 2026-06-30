ALTER TABLE public.payslip_commissions REPLICA IDENTITY FULL;
UPDATE public.payslip_commissions
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.payslip_commissions.tenant_id = t.id AND public.payslip_commissions.platform_id IS NULL;