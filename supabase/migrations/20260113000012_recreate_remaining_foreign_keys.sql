-- Corrección de llaves foráneas conflictivas y recreación sistemática.
-- Este script primero soluciona un conflicto con la llave primaria de `attention_services` y luego recrea las llaves foráneas
-- asegurando que el orden de las columnas en las FK coincida con el orden en las PK referenciadas.

-- Paso 1: Eliminar la llave foránea conflictiva de `signed_consents` que apunta a `attention_services`.
-- Se recreará más adelante con la referencia correcta.
ALTER TABLE public.signed_consents DROP CONSTRAINT IF EXISTS fk_signed_consents_attention_service;

-- Paso 2: Corregir la llave primaria de `attention_services`.
-- La PK original (tenant_id, id, attention_id, platform_id) era difícil de referenciar.
-- Se cambia a (id, tenant_id, platform_id) para consistencia.
ALTER TABLE public.attention_services DROP CONSTRAINT IF EXISTS attention_services_pkey;
ALTER TABLE public.attention_services ADD PRIMARY KEY (id, tenant_id, platform_id);

-- Paso 3: Recrear las llaves foráneas con el orden de columnas corregido.

-- attention_combos
ALTER TABLE public.attention_combos ADD CONSTRAINT attention_combos_attention_id_fkey FOREIGN KEY (attention_id, tenant_id, platform_id) REFERENCES public.attentions(id, tenant_id, platform_id) ON DELETE CASCADE;
ALTER TABLE public.attention_combos ADD CONSTRAINT attention_combos_combo_id_fkey FOREIGN KEY (tenant_id, combo_id, platform_id) REFERENCES public.combos(tenant_id, id, platform_id) ON DELETE CASCADE;
ALTER TABLE public.attention_combos ADD CONSTRAINT attention_combos_tenant_id_fkey FOREIGN KEY (platform_id, tenant_id) REFERENCES public.tenants(platform_id, id) ON DELETE CASCADE;
-- CORREGIDO: Se usan las columnas correctas (branch_id) para la FK.
ALTER TABLE public.attention_combos ADD CONSTRAINT attention_combos_branch_id_fkey FOREIGN KEY (branch_id, platform_id, tenant_id) REFERENCES public.branches(id, platform_id, tenant_id) ON DELETE CASCADE;

-- attention_payment_evidences
ALTER TABLE public.attention_payment_evidences ADD CONSTRAINT fk_ape_attention_payment FOREIGN KEY (tenant_id, attention_payment_id, platform_id) REFERENCES public.attention_payments(tenant_id, id, platform_id) ON DELETE CASCADE;
ALTER TABLE public.attention_payment_evidences ADD CONSTRAINT fk_ape_branch FOREIGN KEY (branch_id, platform_id, tenant_id) REFERENCES public.branches(id, platform_id, tenant_id) ON DELETE CASCADE;
ALTER TABLE public.attention_payment_evidences ADD CONSTRAINT fk_ape_tenant FOREIGN KEY (platform_id, tenant_id) REFERENCES public.tenants(platform_id, id) ON DELETE CASCADE;
ALTER TABLE public.attention_payment_evidences ADD CONSTRAINT fk_ape_user FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE SET NULL;

-- attention_payments
ALTER TABLE public.attention_payments ADD CONSTRAINT attention_payments_attention_id_fkey FOREIGN KEY (attention_id, tenant_id, platform_id) REFERENCES public.attentions(id, tenant_id, platform_id) ON DELETE CASCADE;
ALTER TABLE public.attention_payments ADD CONSTRAINT attention_payments_payment_method_id_fkey FOREIGN KEY (platform_id, tenant_id, payment_method_id) REFERENCES public.payment_methods(platform_id, tenant_id, id) ON DELETE RESTRICT;
ALTER TABLE public.attention_payments ADD CONSTRAINT attention_payments_tenant_id_fkey FOREIGN KEY (platform_id, tenant_id) REFERENCES public.tenants(platform_id, id) ON DELETE CASCADE;

-- attention_service_evidences
ALTER TABLE public.attention_service_evidences ADD CONSTRAINT fk_ase_attention_service FOREIGN KEY (attention_service_id, tenant_id, platform_id) REFERENCES public.attention_services(id, tenant_id, platform_id) ON DELETE CASCADE;
ALTER TABLE public.attention_service_evidences ADD CONSTRAINT fk_ase_branch FOREIGN KEY (branch_id, platform_id, tenant_id) REFERENCES public.branches(id, platform_id, tenant_id) ON DELETE CASCADE;
ALTER TABLE public.attention_service_evidences ADD CONSTRAINT fk_ase_tenant FOREIGN KEY (platform_id, tenant_id) REFERENCES public.tenants(platform_id, id) ON DELETE CASCADE;
ALTER TABLE public.attention_service_evidences ADD CONSTRAINT fk_ase_user FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE SET NULL;

-- attention_service_status_history
-- Se corrige la referencia a la nueva PK de attention_services (sin attention_id).
ALTER TABLE public.attention_service_status_history ADD CONSTRAINT fk_assh_attention_service FOREIGN KEY (attention_service_id, tenant_id, platform_id) REFERENCES public.attention_services(id, tenant_id, platform_id) ON DELETE CASCADE;
ALTER TABLE public.attention_service_status_history ADD CONSTRAINT fk_assh_branch FOREIGN KEY (branch_id, platform_id, tenant_id) REFERENCES public.branches(id, platform_id, tenant_id) ON DELETE CASCADE;
ALTER TABLE public.attention_service_status_history ADD CONSTRAINT fk_assh_tenant FOREIGN KEY (platform_id, tenant_id) REFERENCES public.tenants(platform_id, id) ON DELETE CASCADE;
ALTER TABLE public.attention_service_status_history ADD CONSTRAINT fk_assh_user FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE SET NULL;

-- branch_status_history
ALTER TABLE public.branch_status_history ADD CONSTRAINT branch_status_history_branch_id_fkey FOREIGN KEY (branch_id, platform_id, tenant_id) REFERENCES public.branches(id, platform_id, tenant_id) ON DELETE CASCADE;
ALTER TABLE public.branch_status_history ADD CONSTRAINT branch_status_history_changed_by_fkey FOREIGN KEY (changed_by) REFERENCES auth.users(id) ON DELETE SET NULL;

-- client_commercials
ALTER TABLE public.client_commercials ADD CONSTRAINT client_commercials_client_id_fkey FOREIGN KEY (tenant_id, platform_id, client_id) REFERENCES public.clients(tenant_id, platform_id, id) ON DELETE CASCADE;
ALTER TABLE public.client_commercials ADD CONSTRAINT client_commercials_tenant_id_fkey FOREIGN KEY (platform_id, tenant_id) REFERENCES public.tenants(platform_id, id) ON DELETE CASCADE;
ALTER TABLE public.client_commercials ADD CONSTRAINT client_commercials_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE SET NULL;

-- client_professionals
ALTER TABLE public.client_professionals ADD CONSTRAINT client_professionals_client_id_fkey FOREIGN KEY (tenant_id, platform_id, client_id) REFERENCES public.clients(tenant_id, platform_id, id) ON DELETE CASCADE;
ALTER TABLE public.client_professionals ADD CONSTRAINT client_professionals_tenant_id_fkey FOREIGN KEY (platform_id, tenant_id) REFERENCES public.tenants(platform_id, id) ON DELETE CASCADE;
ALTER TABLE public.client_professionals ADD CONSTRAINT client_professionals_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE RESTRICT;

-- combos
ALTER TABLE public.combos ADD CONSTRAINT combos_tenant_id_fkey FOREIGN KEY (platform_id, tenant_id) REFERENCES public.tenants(platform_id, id) ON DELETE CASCADE;

-- commission_payment_evidences
ALTER TABLE public.commission_payment_evidences ADD CONSTRAINT fk_cpe_branch FOREIGN KEY (branch_id, platform_id, tenant_id) REFERENCES public.branches(id, platform_id, tenant_id) ON DELETE CASCADE;
ALTER TABLE public.commission_payment_evidences ADD CONSTRAINT fk_cpe_payslip FOREIGN KEY (tenant_id, platform_id, payslip_id) REFERENCES public.payslips(tenant_id, platform_id, id) ON DELETE CASCADE;
ALTER TABLE public.commission_payment_evidences ADD CONSTRAINT fk_cpe_tenant FOREIGN KEY (platform_id, tenant_id) REFERENCES public.tenants(platform_id, id) ON DELETE CASCADE;
ALTER TABLE public.commission_payment_evidences ADD CONSTRAINT fk_cpe_user FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE SET NULL;

-- document_sequences
ALTER TABLE public.document_sequences ADD CONSTRAINT document_sequences_branch_id_fkey FOREIGN KEY (branch_id, platform_id, tenant_id) REFERENCES public.branches(id, platform_id, tenant_id) ON DELETE CASCADE;
ALTER TABLE public.document_sequences ADD CONSTRAINT document_sequences_tenant_id_fkey FOREIGN KEY (platform_id, tenant_id) REFERENCES public.tenants(platform_id, id) ON DELETE CASCADE;

-- earned_commissions
ALTER TABLE public.earned_commissions ADD CONSTRAINT earned_commissions_branch_id_fkey FOREIGN KEY (branch_id, platform_id, tenant_id) REFERENCES public.branches(id, platform_id, tenant_id) ON DELETE CASCADE;
ALTER TABLE public.earned_commissions ADD CONSTRAINT earned_commissions_sale_id_fkey FOREIGN KEY (sale_id, platform_id, tenant_id) REFERENCES public.sales(id, platform_id, tenant_id) ON DELETE CASCADE;
ALTER TABLE public.earned_commissions ADD CONSTRAINT earned_commissions_sales_item_id_fkey FOREIGN KEY (tenant_id, sale_id, sales_item_id, platform_id) REFERENCES public.sales_items(tenant_id, sale_id, id, platform_id) ON DELETE CASCADE;
ALTER TABLE public.earned_commissions ADD CONSTRAINT earned_commissions_tenant_id_fkey FOREIGN KEY (platform_id, tenant_id) REFERENCES public.tenants(platform_id, id) ON DELETE CASCADE;
ALTER TABLE public.earned_commissions ADD CONSTRAINT earned_commissions_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

-- extra_service_sessions
ALTER TABLE public.extra_service_sessions ADD CONSTRAINT fk_ess_branch FOREIGN KEY (branch_id, platform_id, tenant_id) REFERENCES public.branches(id, platform_id, tenant_id) ON DELETE CASCADE;
ALTER TABLE public.extra_service_sessions ADD CONSTRAINT fk_ess_tenant FOREIGN KEY (platform_id, tenant_id) REFERENCES public.tenants(platform_id, id) ON DELETE CASCADE;

-- invoice_item_taxes
-- Paso 1: Añadir la columna invoice_id que falta, permitiendo nulos inicialmente.
ALTER TABLE public.invoice_item_taxes ADD COLUMN invoice_id uuid;

-- Paso 2: Poblar la nueva columna con los datos de invoice_items.
UPDATE public.invoice_item_taxes iit
SET invoice_id = ii.invoice_id
FROM public.invoice_items ii
WHERE iit.invoice_item_id = ii.id
  AND iit.tenant_id = ii.tenant_id
  AND iit.platform_id = ii.platform_id;

-- Paso 3: Limpiar posibles huérfanos y asegurar que la columna no sea nula.
DELETE FROM public.invoice_item_taxes WHERE invoice_id IS NULL;
ALTER TABLE public.invoice_item_taxes ALTER COLUMN invoice_id SET NOT NULL;

-- Paso 4: Recrear la llave primaria para incluir invoice_id.
ALTER TABLE public.invoice_item_taxes DROP CONSTRAINT IF EXISTS invoice_item_taxes_pkey;
ALTER TABLE public.invoice_item_taxes ADD CONSTRAINT invoice_item_taxes_pkey PRIMARY KEY (invoice_id, invoice_item_id, tax_id, tenant_id, platform_id);

-- Paso 5: Crear la llave foránea a invoice_items, que ahora funcionará.
ALTER TABLE public.invoice_item_taxes ADD CONSTRAINT invoice_item_taxes_invoice_item_id_fkey FOREIGN KEY (invoice_id, invoice_item_id, platform_id, tenant_id) REFERENCES public.invoice_items(invoice_id, id, platform_id, tenant_id) ON DELETE CASCADE;

-- La FK a tax_types debe permanecer.
ALTER TABLE public.invoice_item_taxes ADD CONSTRAINT invoice_item_taxes_tax_id_fkey FOREIGN KEY (platform_id, tenant_id, tax_id) REFERENCES public.tax_types(platform_id, tenant_id, id) ON DELETE RESTRICT;

-- notifications
ALTER TABLE public.notifications ADD CONSTRAINT notifications_tenant_id_fkey FOREIGN KEY (platform_id, tenant_id) REFERENCES public.tenants(platform_id, id) ON DELETE CASCADE;
ALTER TABLE public.notifications ADD CONSTRAINT notifications_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

-- payment_methods
ALTER TABLE public.payment_methods ADD CONSTRAINT payment_methods_tenant_id_fkey FOREIGN KEY (platform_id, tenant_id) REFERENCES public.tenants(platform_id, id) ON DELETE CASCADE;

-- payslip_commissions
ALTER TABLE public.payslip_commissions ADD CONSTRAINT payslip_commissions_commission_id_fkey FOREIGN KEY (commission_id, tenant_id, platform_id) REFERENCES public.earned_commissions(id, tenant_id, platform_id) ON DELETE CASCADE;
ALTER TABLE public.payslip_commissions ADD CONSTRAINT payslip_commissions_payslip_id_fkey FOREIGN KEY (tenant_id, platform_id, payslip_id) REFERENCES public.payslips(tenant_id, platform_id, id) ON DELETE CASCADE;

-- payslips
ALTER TABLE public.payslips ADD CONSTRAINT payslips_branch_id_fkey FOREIGN KEY (branch_id, platform_id, tenant_id) REFERENCES public.branches(id, platform_id, tenant_id) ON DELETE CASCADE;
ALTER TABLE public.payslips ADD CONSTRAINT payslips_tenant_id_fkey FOREIGN KEY (platform_id, tenant_id) REFERENCES public.tenants(platform_id, id) ON DELETE CASCADE;
ALTER TABLE public.payslips ADD CONSTRAINT payslips_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

-- performance_metrics
ALTER TABLE public.performance_metrics ADD CONSTRAINT performance_metrics_tenant_id_fkey FOREIGN KEY (platform_id, tenant_id) REFERENCES public.tenants(platform_id, id) ON DELETE CASCADE;

-- product_tax_types
ALTER TABLE public.product_tax_types ADD CONSTRAINT product_tax_types_product_id_fkey FOREIGN KEY (tenant_id, product_id, platform_id) REFERENCES public.products(tenant_id, id, platform_id) ON DELETE CASCADE;
ALTER TABLE public.product_tax_types ADD CONSTRAINT product_tax_types_tax_type_id_fkey FOREIGN KEY (platform_id, tenant_id, tax_type_id) REFERENCES public.tax_types(platform_id, tenant_id, id) ON DELETE CASCADE;
ALTER TABLE public.product_tax_types ADD CONSTRAINT product_tax_types_tenant_id_fkey FOREIGN KEY (platform_id, tenant_id) REFERENCES public.tenants(platform_id, id) ON DELETE CASCADE;

-- purchase_item_receptions
-- Paso 1: Añadir la columna purchase_id que falta.
ALTER TABLE public.purchase_item_receptions ADD COLUMN purchase_id uuid;

-- Paso 2: Poblar la nueva columna con los datos de purchase_items.
UPDATE public.purchase_item_receptions pir
SET purchase_id = pi.purchase_id
FROM public.purchase_items pi
WHERE pir.purchase_item_id = pi.id
  AND pir.tenant_id = pi.tenant_id
  AND pir.platform_id = pi.platform_id;

-- Paso 3: Limpiar posibles huérfanos y asegurar que la columna no sea nula.
DELETE FROM public.purchase_item_receptions WHERE purchase_id IS NULL;
ALTER TABLE public.purchase_item_receptions ALTER COLUMN purchase_id SET NOT NULL;

-- Paso 4: Recrear la llave primaria para incluir purchase_id.
ALTER TABLE public.purchase_item_receptions DROP CONSTRAINT IF EXISTS purchase_item_receptions_pkey;
ALTER TABLE public.purchase_item_receptions ADD CONSTRAINT purchase_item_receptions_pkey PRIMARY KEY (id, purchase_id, tenant_id, platform_id);

-- Paso 5: Crear la llave foránea a purchase_items, que ahora funcionará.
ALTER TABLE public.purchase_item_receptions ADD CONSTRAINT pir_purchase_item_id_fkey FOREIGN KEY (platform_id, purchase_item_id, purchase_id, tenant_id) REFERENCES public.purchase_items(platform_id, id, purchase_id, tenant_id) ON DELETE CASCADE;

-- La FK a tenants debe permanecer.
ALTER TABLE public.purchase_item_receptions ADD CONSTRAINT pir_tenant_id_fkey FOREIGN KEY (platform_id, tenant_id) REFERENCES public.tenants(platform_id, id) ON DELETE CASCADE;

-- rescheduled_attentions
ALTER TABLE public.rescheduled_attentions ADD CONSTRAINT rescheduled_attentions_attention_id_fkey FOREIGN KEY (attention_id, tenant_id, platform_id) REFERENCES public.attentions(id, tenant_id, platform_id) ON DELETE CASCADE;
ALTER TABLE public.rescheduled_attentions ADD CONSTRAINT rescheduled_attentions_client_id_fkey FOREIGN KEY (tenant_id, platform_id, client_id) REFERENCES public.clients(tenant_id, platform_id, id) ON DELETE CASCADE;
ALTER TABLE public.rescheduled_attentions ADD CONSTRAINT rescheduled_attentions_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE SET NULL;

-- satisfaction_survey_ratings
ALTER TABLE public.satisfaction_survey_ratings ADD CONSTRAINT fk_ssr_attention_service FOREIGN KEY (attention_service_id, tenant_id, platform_id) REFERENCES public.attention_services(id, tenant_id, platform_id) ON DELETE SET NULL;
ALTER TABLE public.satisfaction_survey_ratings ADD CONSTRAINT fk_ssr_branch FOREIGN KEY (branch_id, platform_id, tenant_id) REFERENCES public.branches(id, platform_id, tenant_id) ON DELETE CASCADE;
ALTER TABLE public.satisfaction_survey_ratings ADD CONSTRAINT fk_ssr_survey FOREIGN KEY (platform_id, survey_id, tenant_id) REFERENCES public.satisfaction_surveys(platform_id, id, tenant_id) ON DELETE CASCADE;
ALTER TABLE public.satisfaction_survey_ratings ADD CONSTRAINT fk_ssr_tenant FOREIGN KEY (platform_id, tenant_id) REFERENCES public.tenants(platform_id, id) ON DELETE CASCADE;

-- satisfaction_surveys
ALTER TABLE public.satisfaction_surveys ADD CONSTRAINT fk_ss_attention FOREIGN KEY (attention_id, tenant_id, platform_id) REFERENCES public.attentions(id, tenant_id, platform_id) ON DELETE CASCADE;
ALTER TABLE public.satisfaction_surveys ADD CONSTRAINT fk_ss_branch FOREIGN KEY (branch_id, platform_id, tenant_id) REFERENCES public.branches(id, platform_id, tenant_id) ON DELETE CASCADE;
ALTER TABLE public.satisfaction_surveys ADD CONSTRAINT fk_ss_client FOREIGN KEY (tenant_id, platform_id, client_id) REFERENCES public.clients(tenant_id, platform_id, id) ON DELETE CASCADE;
ALTER TABLE public.satisfaction_surveys ADD CONSTRAINT fk_ss_tenant FOREIGN KEY (platform_id, tenant_id) REFERENCES public.tenants(platform_id, id) ON DELETE CASCADE;

-- schedule_templates
ALTER TABLE public.schedule_templates ADD CONSTRAINT fk_schedule_templates_tenant FOREIGN KEY (platform_id, tenant_id) REFERENCES public.tenants(platform_id, id) ON DELETE CASCADE;

-- service_tax_types
ALTER TABLE public.service_tax_types ADD CONSTRAINT service_tax_types_service_id_fkey FOREIGN KEY (tenant_id, service_id, platform_id) REFERENCES public.services(tenant_id, id, platform_id) ON DELETE CASCADE;
ALTER TABLE public.service_tax_types ADD CONSTRAINT service_tax_types_tax_type_id_fkey FOREIGN KEY (platform_id, tenant_id, tax_type_id) REFERENCES public.tax_types(platform_id, tenant_id, id) ON DELETE CASCADE;
ALTER TABLE public.service_tax_types ADD CONSTRAINT service_tax_types_tenant_id_fkey FOREIGN KEY (platform_id, tenant_id) REFERENCES public.tenants(platform_id, id) ON DELETE CASCADE;

-- service_user_commissions
ALTER TABLE public.service_user_commissions ADD CONSTRAINT fk_suc_branch FOREIGN KEY (branch_id, platform_id, tenant_id) REFERENCES public.branches(id, platform_id, tenant_id) ON DELETE CASCADE;
ALTER TABLE public.service_user_commissions ADD CONSTRAINT fk_suc_tenant FOREIGN KEY (platform_id, tenant_id) REFERENCES public.tenants(platform_id, id) ON DELETE CASCADE;
ALTER TABLE public.service_user_commissions ADD CONSTRAINT suc_service_id_fkey FOREIGN KEY (tenant_id, service_id, platform_id) REFERENCES public.services(tenant_id, id, platform_id) ON DELETE CASCADE;
ALTER TABLE public.service_user_commissions ADD CONSTRAINT suc_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

-- staff_gallery_items
ALTER TABLE public.staff_gallery_items ADD CONSTRAINT staff_gallery_items_evidence_id_fkey FOREIGN KEY (evidence_id, platform_id, tenant_id) REFERENCES public.attention_service_evidences(id, platform_id, tenant_id) ON DELETE CASCADE;
ALTER TABLE public.staff_gallery_items ADD CONSTRAINT staff_gallery_items_tenant_id_fkey FOREIGN KEY (platform_id, tenant_id) REFERENCES public.tenants(platform_id, id) ON DELETE CASCADE;
ALTER TABLE public.staff_gallery_items ADD CONSTRAINT staff_gallery_items_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

-- supplier_addresses
ALTER TABLE public.supplier_addresses ADD CONSTRAINT supplier_addresses_supplier_id_fkey FOREIGN KEY (tenant_id, platform_id, supplier_id) REFERENCES public.suppliers(tenant_id, platform_id, id) ON DELETE CASCADE;
ALTER TABLE public.supplier_addresses ADD CONSTRAINT supplier_addresses_tenant_id_fkey FOREIGN KEY (platform_id, tenant_id) REFERENCES public.tenants(platform_id, id) ON DELETE CASCADE;

-- supplier_contacts
ALTER TABLE public.supplier_contacts ADD CONSTRAINT supplier_contacts_contact_type_id_fkey FOREIGN KEY (platform_id, tenant_id, contact_type_id) REFERENCES public.contact_types(platform_id, tenant_id, id) ON DELETE RESTRICT;
ALTER TABLE public.supplier_contacts ADD CONSTRAINT supplier_contacts_supplier_id_fkey FOREIGN KEY (tenant_id, platform_id, supplier_id) REFERENCES public.suppliers(tenant_id, platform_id, id) ON DELETE CASCADE;
ALTER TABLE public.supplier_contacts ADD CONSTRAINT supplier_contacts_tenant_id_fkey FOREIGN KEY (platform_id, tenant_id) REFERENCES public.tenants(platform_id, id) ON DELETE CASCADE;

-- supplier_products
ALTER TABLE public.supplier_products ADD CONSTRAINT fk_supplier_products_tenant FOREIGN KEY (platform_id, tenant_id) REFERENCES public.tenants(platform_id, id) ON DELETE CASCADE;
ALTER TABLE public.supplier_products ADD CONSTRAINT supplier_products_product_id_fkey FOREIGN KEY (tenant_id, product_id, platform_id) REFERENCES public.products(tenant_id, id, platform_id) ON DELETE CASCADE;
ALTER TABLE public.supplier_products ADD CONSTRAINT supplier_products_supplier_id_fkey FOREIGN KEY (tenant_id, platform_id, supplier_id) REFERENCES public.suppliers(tenant_id, platform_id, id) ON DELETE CASCADE;

-- tenant_client_settings
ALTER TABLE public.tenant_client_settings ADD CONSTRAINT tcs_default_intake_form_id_fkey FOREIGN KEY (default_intake_form_id, tenant_id, platform_id) REFERENCES public.client_document_templates(id, tenant_id, platform_id) ON DELETE SET NULL;
ALTER TABLE public.tenant_client_settings ADD CONSTRAINT tcs_tenant_id_fkey FOREIGN KEY (platform_id, tenant_id) REFERENCES public.tenants(platform_id, id) ON DELETE CASCADE;

-- tenant_settings
ALTER TABLE public.tenant_settings ADD CONSTRAINT tenant_settings_tenant_id_fkey FOREIGN KEY (platform_id, tenant_id) REFERENCES public.tenants(platform_id, id) ON DELETE CASCADE;

-- turns
ALTER TABLE public.turns ADD CONSTRAINT turns_attention_id_fkey FOREIGN KEY (attention_id, tenant_id, platform_id) REFERENCES public.attentions(id, tenant_id, platform_id) ON DELETE SET NULL;
ALTER TABLE public.turns ADD CONSTRAINT turns_branch_id_fkey FOREIGN KEY (branch_id, platform_id, tenant_id) REFERENCES public.branches(id, platform_id, tenant_id) ON DELETE CASCADE;
ALTER TABLE public.turns ADD CONSTRAINT turns_client_id_fkey FOREIGN KEY (tenant_id, platform_id, client_id) REFERENCES public.clients(tenant_id, platform_id, id) ON DELETE CASCADE;
ALTER TABLE public.turns ADD CONSTRAINT turns_stylist_id_fkey FOREIGN KEY (stylist_id) REFERENCES auth.users(id) ON DELETE CASCADE;
ALTER TABLE public.turns ADD CONSTRAINT turns_tenant_id_fkey FOREIGN KEY (platform_id, tenant_id) REFERENCES public.tenants(platform_id, id) ON DELETE CASCADE;

-- units_of_measure
ALTER TABLE public.units_of_measure ADD CONSTRAINT units_of_measure_tenant_id_fkey FOREIGN KEY (platform_id, tenant_id) REFERENCES public.tenants(platform_id, id) ON DELETE CASCADE;

-- user_avatars
ALTER TABLE public.user_avatars ADD CONSTRAINT fk_user_avatars_tenant FOREIGN KEY (platform_id, tenant_id) REFERENCES public.tenants(platform_id, id) ON DELETE CASCADE;

-- user_schedules
ALTER TABLE public.user_schedules ADD CONSTRAINT stylist_schedules_template_id_fkey FOREIGN KEY (tenant_id, platform_id, template_id) REFERENCES public.schedule_templates(tenant_id, platform_id, id) ON DELETE SET NULL;
ALTER TABLE public.user_schedules ADD CONSTRAINT user_schedules_branch_id_fkey FOREIGN KEY (branch_id, platform_id, tenant_id) REFERENCES public.branches(id, platform_id, tenant_id) ON DELETE CASCADE;
ALTER TABLE public.user_schedules ADD CONSTRAINT user_schedules_tenant_id_fkey FOREIGN KEY (platform_id, tenant_id) REFERENCES public.tenants(platform_id, id) ON DELETE CASCADE;

-- user_time_off
-- CORREGIDO: Se usan las columnas correctas (absence_type_id) para la FK.
ALTER TABLE public.user_time_off ADD CONSTRAINT user_time_off_absence_type_id_fkey FOREIGN KEY (absence_type_id, platform_id, tenant_id) REFERENCES public.absence_types(id, platform_id, tenant_id) ON DELETE RESTRICT;
ALTER TABLE public.user_time_off ADD CONSTRAINT user_time_off_branch_id_fkey FOREIGN KEY (branch_id, platform_id, tenant_id) REFERENCES public.branches(id, platform_id, tenant_id) ON DELETE CASCADE;
ALTER TABLE public.user_time_off ADD CONSTRAINT user_time_off_tenant_id_fkey FOREIGN KEY (platform_id, tenant_id) REFERENCES public.tenants(platform_id, id) ON DELETE CASCADE;

-- Paso 4: Recrear la FK de `signed_consents` que fue eliminada al principio.
-- Ahora apunta a la nueva PK de `attention_services`.
ALTER TABLE public.signed_consents ADD CONSTRAINT fk_signed_consents_attention_service FOREIGN KEY (attention_service_id, tenant_id, platform_id) REFERENCES public.attention_services(id, tenant_id, platform_id) ON DELETE CASCADE;
