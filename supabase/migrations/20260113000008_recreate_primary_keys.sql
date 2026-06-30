-- Drop unused tables
DROP TABLE IF EXISTS public.appointments CASCADE;
DROP TABLE IF EXISTS public.appointment_products CASCADE;
DROP TABLE IF EXISTS public.appointment_sessions CASCADE;
DROP TABLE IF EXISTS public.appointment_extra_services CASCADE;
DROP TABLE IF EXISTS public.branch_playback_state CASCADE;

-- Clear tables to prevent PK violation on null platform_id
TRUNCATE TABLE public.audit_logs;
TRUNCATE TABLE public.api_request_metrics;

-- Delete orphan record from user_assignments
DELETE FROM public.user_assignments WHERE id = 'bec7e802-a579-4909-b8c5-a427205af638';

-- Delete orphan tv_displays records
ALTER TABLE public.tv_displays REPLICA IDENTITY FULL;
DELETE FROM public.tv_displays WHERE id IN (
    '34266c92-49ee-4ce2-943f-65505a9aba85',
    '6929b88d-d0b0-4767-bf91-b02b7b2fc213',
    '8f8e48cf-9b28-43bb-8872-a8203ff0a859',
    'a836c8b1-f6f0-461e-abf2-9648b0da01a0',
    'cdc297c4-c64f-4743-b54b-3a210e8956ff',
    'cf6970d8-4c61-4f41-80f8-158540888cd6',
    'f1b2bade-601d-4a0c-ab4b-758f3d719eeb'
);

-- Fix branch_status_history schema and data
DELETE FROM public.branch_status_history WHERE id = 41;
ALTER TABLE public.branch_status_history REPLICA IDENTITY FULL;
UPDATE public.branch_status_history SET tenant_id = b.tenant_id FROM public.branches b WHERE public.branch_status_history.branch_id = b.id AND public.branch_status_history.tenant_id IS NULL;
UPDATE public.branch_status_history SET platform_id = t.platform_id FROM public.tenants t WHERE public.branch_status_history.tenant_id = t.id AND public.branch_status_history.platform_id IS NULL;
ALTER TABLE public.branch_status_history ADD COLUMN uuid_id UUID NOT NULL DEFAULT gen_random_uuid();
ALTER TABLE public.branch_status_history DROP COLUMN id CASCADE;
ALTER TABLE public.branch_status_history RENAME COLUMN uuid_id TO id;

-- Backfill platform_id for user_assignments before creating PK
ALTER TABLE public.user_assignments REPLICA IDENTITY FULL;
UPDATE public.user_assignments
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.user_assignments.tenant_id = t.id AND public.user_assignments.platform_id IS NULL;

-- Backfill platform_id for product_transfer_items before creating PK
ALTER TABLE public.product_transfer_items REPLICA IDENTITY FULL;
UPDATE public.product_transfer_items
SET platform_id = t.platform_id
FROM public.product_transfers pt
JOIN public.tenants t ON pt.tenant_id = t.id
WHERE public.product_transfer_items.transfer_id = pt.id AND public.product_transfer_items.platform_id IS NULL;


-- Recreate Primary Keys
ALTER TABLE public.absence_types ADD CONSTRAINT absence_types_pkey PRIMARY KEY (id, platform_id, tenant_id);
ALTER TABLE public.api_request_metrics ADD CONSTRAINT api_request_metrics_pkey PRIMARY KEY (tenant_id, id, platform_id);
ALTER TABLE public.attention_combos ADD CONSTRAINT attention_combos_pkey PRIMARY KEY (id, platform_id, tenant_id);
ALTER TABLE public.attention_payment_evidences ADD CONSTRAINT attention_payment_evidences_pkey PRIMARY KEY (tenant_id, id, platform_id);
ALTER TABLE public.attention_payments ADD CONSTRAINT attention_payments_pkey PRIMARY KEY (tenant_id, id, platform_id);
ALTER TABLE public.attention_products ADD CONSTRAINT attention_products_pkey PRIMARY KEY (platform_id, tenant_id, attention_id, id);
ALTER TABLE public.attention_service_evidences ADD CONSTRAINT attention_service_evidences_pkey PRIMARY KEY (platform_id, tenant_id, id);
ALTER TABLE public.attention_service_status_history ADD CONSTRAINT attention_service_status_history_pkey PRIMARY KEY (id, platform_id, tenant_id);
ALTER TABLE public.attention_services ADD CONSTRAINT attention_services_pkey PRIMARY KEY (tenant_id, id, attention_id, platform_id);
ALTER TABLE public.attentions ADD CONSTRAINT attentions_pkey PRIMARY KEY (id, tenant_id, platform_id);
ALTER TABLE public.audit_logs ADD CONSTRAINT audit_logs_pkey PRIMARY KEY (platform_id, id, tenant_id);
ALTER TABLE public.branch_combo_item_prices ADD CONSTRAINT branch_combo_item_prices_pkey PRIMARY KEY (id, platform_id, tenant_id);
ALTER TABLE public.branch_combos ADD CONSTRAINT branch_combos_pkey PRIMARY KEY (tenant_id, platform_id, branch_id, combo_id);
ALTER TABLE public.branch_photos ADD CONSTRAINT branch_photos_pkey PRIMARY KEY (platform_id, id, branch_id, tenant_id);
ALTER TABLE public.branch_products ADD CONSTRAINT branch_products_pkey PRIMARY KEY (branch_id, platform_id, tenant_id, product_id);
ALTER TABLE public.branch_services ADD CONSTRAINT branch_services_pkey PRIMARY KEY (service_id, branch_id, platform_id, tenant_id);
ALTER TABLE public.branch_social_networks ADD CONSTRAINT branch_social_networks_pkey PRIMARY KEY (tenant_id, id, branch_id, platform_id);
ALTER TABLE public.branch_status_history ADD CONSTRAINT branch_status_history_pkey PRIMARY KEY (id, tenant_id, platform_id);
ALTER TABLE public.branches ADD CONSTRAINT branches_pkey PRIMARY KEY (id, platform_id, tenant_id);
ALTER TABLE public.chatter_attachments ADD CONSTRAINT chatter_attachments_pkey PRIMARY KEY (tenant_id, id, platform_id, chatter_comment_id);
ALTER TABLE public.chatter_comments ADD CONSTRAINT chatter_comments_pkey PRIMARY KEY (tenant_id, id, platform_id);
ALTER TABLE public.client_addresses ADD CONSTRAINT client_addresses_pkey PRIMARY KEY (tenant_id, platform_id, id);
ALTER TABLE public.client_branches ADD CONSTRAINT client_branches_pkey PRIMARY KEY (platform_id, client_id, branch_id, tenant_id);
ALTER TABLE public.client_commercials ADD CONSTRAINT client_commercials_pkey PRIMARY KEY (id, platform_id, tenant_id);
ALTER TABLE public.client_consent_records ADD CONSTRAINT client_consent_records_pkey PRIMARY KEY (tenant_id, platform_id, id);
ALTER TABLE public.client_contacts ADD CONSTRAINT client_contacts_pkey PRIMARY KEY (platform_id, id, tenant_id);
ALTER TABLE public.client_document_instances ADD CONSTRAINT client_document_instances_pkey PRIMARY KEY (id, platform_id, tenant_id);
ALTER TABLE public.client_document_templates ADD CONSTRAINT client_document_templates_pkey PRIMARY KEY (id, tenant_id, platform_id);
ALTER TABLE public.client_professionals ADD CONSTRAINT client_professionals_pkey PRIMARY KEY (id, platform_id, tenant_id);
ALTER TABLE public.client_treatment_session_items ADD CONSTRAINT client_treatment_session_items_pkey PRIMARY KEY (client_treatment_session_id, id, tenant_id, platform_id);
ALTER TABLE public.client_treatment_sessions ADD CONSTRAINT client_treatment_sessions_pkey PRIMARY KEY (id, platform_id, tenant_id);
ALTER TABLE public.client_treatments ADD CONSTRAINT client_treatments_pkey PRIMARY KEY (tenant_id, platform_id, id);
ALTER TABLE public.clients ADD CONSTRAINT clients_pkey PRIMARY KEY (tenant_id, platform_id, id);
ALTER TABLE public.combo_images ADD CONSTRAINT combo_images_pkey PRIMARY KEY (id, tenant_id, platform_id, combo_id);
ALTER TABLE public.combo_items ADD CONSTRAINT combo_items_pkey PRIMARY KEY (combo_id, platform_id, tenant_id, id);
ALTER TABLE public.combos ADD CONSTRAINT combos_pkey PRIMARY KEY (tenant_id, id, platform_id);
ALTER TABLE public.commission_payment_evidences ADD CONSTRAINT commission_payment_evidences_pkey PRIMARY KEY (id, platform_id, tenant_id);
ALTER TABLE public.consent_signatures ADD CONSTRAINT consent_signatures_pkey PRIMARY KEY (id, platform_id, tenant_id);
ALTER TABLE public.contact_types ADD CONSTRAINT contact_types_pkey PRIMARY KEY (platform_id, tenant_id, id);
ALTER TABLE public.document_sequences ADD CONSTRAINT document_sequences_pkey PRIMARY KEY (platform_id, id, tenant_id);
ALTER TABLE public.document_types ADD CONSTRAINT document_types_pkey PRIMARY KEY (platform_id, tenant_id, id);
ALTER TABLE public.earned_commissions ADD CONSTRAINT earned_commissions_pkey PRIMARY KEY (id, tenant_id, platform_id);
ALTER TABLE public.equipment ADD CONSTRAINT equipment_pkey PRIMARY KEY (tenant_id, id, platform_id);
ALTER TABLE public.equipment_assignments ADD CONSTRAINT equipment_assignments_pkey PRIMARY KEY (id, platform_id, tenant_id);
ALTER TABLE public.equipment_brands ADD CONSTRAINT equipment_brands_pkey PRIMARY KEY (tenant_id, id, platform_id);
ALTER TABLE public.equipment_maintenance_history ADD CONSTRAINT equipment_maintenance_history_pkey PRIMARY KEY (platform_id, id, tenant_id, equipment_id);
ALTER TABLE public.equipment_types ADD CONSTRAINT equipment_types_pkey PRIMARY KEY (tenant_id, id, platform_id);
ALTER TABLE public.expense_provider_addresses ADD CONSTRAINT expense_provider_addresses_pkey PRIMARY KEY (platform_id, expense_provider_id, tenant_id, id);
ALTER TABLE public.expense_provider_contacts ADD CONSTRAINT expense_provider_contacts_pkey PRIMARY KEY (expense_provider_id, id, tenant_id, platform_id);
ALTER TABLE public.expense_providers ADD CONSTRAINT expense_providers_pkey PRIMARY KEY (id, tenant_id, platform_id);
ALTER TABLE public.expenses ADD CONSTRAINT expenses_pkey PRIMARY KEY (id, platform_id, tenant_id);
ALTER TABLE public.extra_service_sessions ADD CONSTRAINT extra_service_sessions_pkey PRIMARY KEY (id, tenant_id, platform_id);
ALTER TABLE public.informed_consent_templates ADD CONSTRAINT informed_consent_templates_pkey PRIMARY KEY (platform_id, tenant_id, id);
ALTER TABLE public.invoice_item_taxes ADD CONSTRAINT invoice_item_taxes_pkey PRIMARY KEY (invoice_item_id, tax_id, tenant_id, platform_id);
ALTER TABLE public.invoice_items ADD CONSTRAINT invoice_items_pkey PRIMARY KEY (invoice_id, id, platform_id, tenant_id);
ALTER TABLE public.invoices ADD CONSTRAINT invoices_pkey PRIMARY KEY (platform_id, id, tenant_id);
ALTER TABLE public.media_playlists ADD CONSTRAINT media_playlists_pkey PRIMARY KEY (tenant_id, platform_id, id);
ALTER TABLE public.notifications ADD CONSTRAINT notifications_pkey PRIMARY KEY (tenant_id, id, platform_id);
ALTER TABLE public.payment_methods ADD CONSTRAINT payment_methods_pkey PRIMARY KEY (platform_id, tenant_id, id);
ALTER TABLE public.payslip_commissions ADD CONSTRAINT payslip_commissions_pkey PRIMARY KEY (platform_id, payslip_id, commission_id, tenant_id);
ALTER TABLE public.payslips ADD CONSTRAINT payslips_pkey PRIMARY KEY (tenant_id, platform_id, id);
ALTER TABLE public.performance_metrics ADD CONSTRAINT performance_metrics_pkey PRIMARY KEY (tenant_id, id, platform_id);
ALTER TABLE public.playlist_items ADD CONSTRAINT playlist_items_pkey PRIMARY KEY (tenant_id, platform_id, id, playlist_id);
ALTER TABLE public.product_brands ADD CONSTRAINT product_brands_pkey PRIMARY KEY (tenant_id, id, platform_id);
ALTER TABLE public.product_categories ADD CONSTRAINT product_categories_pkey PRIMARY KEY (platform_id, id, tenant_id);
ALTER TABLE public.product_category_assignments ADD CONSTRAINT product_category_assignments_pkey PRIMARY KEY (platform_id, product_id, category_id, tenant_id);
ALTER TABLE public.product_images ADD CONSTRAINT product_images_pkey PRIMARY KEY (platform_id, product_id, id, tenant_id);
ALTER TABLE public.product_movements ADD CONSTRAINT product_movements_pkey PRIMARY KEY (id, platform_id, tenant_id);
ALTER TABLE public.product_tax_types ADD CONSTRAINT product_tax_types_pkey PRIMARY KEY (product_id, tax_type_id, tenant_id, platform_id);
ALTER TABLE public.product_transfer_items ADD CONSTRAINT product_transfer_items_pkey PRIMARY KEY (platform_id, id, tenant_id);
ALTER TABLE public.product_transfer_reception_items ADD CONSTRAINT product_transfer_reception_items_pkey PRIMARY KEY (id, tenant_id, platform_id, reception_id);
ALTER TABLE public.product_transfer_receptions ADD CONSTRAINT product_transfer_receptions_pkey PRIMARY KEY (tenant_id, platform_id, id);
ALTER TABLE public.product_transfers ADD CONSTRAINT product_transfers_pkey PRIMARY KEY (id, tenant_id, platform_id);
ALTER TABLE public.product_user_commissions ADD CONSTRAINT product_user_commissions_pkey PRIMARY KEY (platform_id, tenant_id, id);
ALTER TABLE public.products ADD CONSTRAINT products_pkey PRIMARY KEY (tenant_id, id, platform_id);
ALTER TABLE public.purchase_item_receptions ADD CONSTRAINT purchase_item_receptions_pkey PRIMARY KEY (id, tenant_id, platform_id);
ALTER TABLE public.purchase_items ADD CONSTRAINT purchase_items_pkey PRIMARY KEY (platform_id, id, purchase_id, tenant_id);
ALTER TABLE public.purchases ADD CONSTRAINT purchases_pkey PRIMARY KEY (platform_id, tenant_id, id);
ALTER TABLE public.recurring_expenses ADD CONSTRAINT recurring_expenses_pkey PRIMARY KEY (tenant_id, id, platform_id);
ALTER TABLE public.rescheduled_attentions ADD CONSTRAINT rescheduled_attentions_pkey PRIMARY KEY (id, attention_id, platform_id, tenant_id);
ALTER TABLE public.roles ADD CONSTRAINT roles_pkey PRIMARY KEY (id);
ALTER TABLE public.sales ADD CONSTRAINT sales_pkey PRIMARY KEY (id, platform_id, tenant_id);
ALTER TABLE public.sales_items ADD CONSTRAINT sales_items_pkey PRIMARY KEY (tenant_id, sale_id, id, platform_id);
ALTER TABLE public.satisfaction_survey_ratings ADD CONSTRAINT satisfaction_survey_ratings_pkey PRIMARY KEY (platform_id, survey_id, id, tenant_id);
ALTER TABLE public.satisfaction_surveys ADD CONSTRAINT satisfaction_surveys_pkey PRIMARY KEY (platform_id, id, tenant_id);
ALTER TABLE public.schedule_templates ADD CONSTRAINT schedule_templates_pkey PRIMARY KEY (tenant_id, platform_id, id);
ALTER TABLE public.service_categories ADD CONSTRAINT service_categories_pkey PRIMARY KEY (id, tenant_id, platform_id);
ALTER TABLE public.service_images ADD CONSTRAINT service_images_pkey PRIMARY KEY (service_id, id, tenant_id, platform_id);
ALTER TABLE public.service_sessions ADD CONSTRAINT service_sessions_pkey PRIMARY KEY (id, platform_id, tenant_id);
ALTER TABLE public.service_tax_types ADD CONSTRAINT service_tax_types_pkey PRIMARY KEY (service_id, tenant_id, tax_type_id, platform_id);
ALTER TABLE public.service_user_commissions ADD CONSTRAINT service_user_commissions_pkey PRIMARY KEY (platform_id, id, tenant_id);
ALTER TABLE public.services ADD CONSTRAINT services_pkey PRIMARY KEY (tenant_id, id, platform_id);
ALTER TABLE public.signed_consents ADD CONSTRAINT signed_consents_pkey PRIMARY KEY (platform_id, tenant_id, id);
ALTER TABLE public.staff_gallery_items ADD CONSTRAINT staff_gallery_items_pkey PRIMARY KEY (id, tenant_id, platform_id);
ALTER TABLE public.supplier_addresses ADD CONSTRAINT supplier_addresses_pkey PRIMARY KEY (id, supplier_id, tenant_id, platform_id);
ALTER TABLE public.supplier_contacts ADD CONSTRAINT supplier_contacts_pkey PRIMARY KEY (platform_id, supplier_id, id, tenant_id);
ALTER TABLE public.supplier_products ADD CONSTRAINT supplier_products_pkey PRIMARY KEY (platform_id, tenant_id, id);
ALTER TABLE public.suppliers ADD CONSTRAINT suppliers_pkey PRIMARY KEY (tenant_id, platform_id, id);
ALTER TABLE public.tax_types ADD CONSTRAINT tax_types_pkey PRIMARY KEY (platform_id, tenant_id, id);
ALTER TABLE public.tenant_client_settings ADD CONSTRAINT tenant_client_settings_pkey PRIMARY KEY (tenant_id, platform_id, id);
ALTER TABLE public.tenant_settings ADD CONSTRAINT tenant_settings_pkey PRIMARY KEY (platform_id, tenant_id);
ALTER TABLE public.tenant_social_networks ADD CONSTRAINT tenant_social_networks_pkey PRIMARY KEY (id, platform_id, tenant_id);
ALTER TABLE public.tenants ADD CONSTRAINT tenants_pkey PRIMARY KEY (platform_id, id);
ALTER TABLE public.treatment_categories ADD CONSTRAINT treatment_categories_pkey PRIMARY KEY (id, tenant_id, platform_id);
ALTER TABLE public.treatment_category_assignments ADD CONSTRAINT treatment_category_assignments_pkey PRIMARY KEY (treatment_id, platform_id, tenant_id, category_id);
ALTER TABLE public.treatment_images ADD CONSTRAINT treatment_images_pkey PRIMARY KEY (tenant_id, id, platform_id, treatment_id);
ALTER TABLE public.treatment_session_items ADD CONSTRAINT treatment_session_items_pkey PRIMARY KEY (platform_id, id, session_id, tenant_id);
ALTER TABLE public.treatment_sessions ADD CONSTRAINT treatment_sessions_pkey PRIMARY KEY (id, tenant_id, platform_id);
ALTER TABLE public.treatments ADD CONSTRAINT treatments_pkey PRIMARY KEY (id, platform_id, tenant_id);
ALTER TABLE public.turns ADD CONSTRAINT turns_pkey PRIMARY KEY (tenant_id, platform_id, id);
ALTER TABLE public.tv_displays ADD CONSTRAINT tv_displays_pkey PRIMARY KEY (id, tenant_id, platform_id);
ALTER TABLE public.units_of_measure ADD CONSTRAINT units_of_measure_pkey PRIMARY KEY (platform_id, tenant_id, id);
ALTER TABLE public.user_assignments ADD CONSTRAINT user_assignments_pkey PRIMARY KEY (platform_id, id, tenant_id);
ALTER TABLE public.user_avatars ADD CONSTRAINT user_avatars_pkey PRIMARY KEY (tenant_id, platform_id, id, user_id);
ALTER TABLE public.user_schedules ADD CONSTRAINT user_schedules_pkey PRIMARY KEY (tenant_id, id, platform_id);
ALTER TABLE public.user_time_off ADD CONSTRAINT user_time_off_pkey PRIMARY KEY (tenant_id, platform_id, id);