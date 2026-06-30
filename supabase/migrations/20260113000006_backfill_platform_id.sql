-- DROP problematic tables that are not part of the core migration and are causing issues
DROP TABLE IF EXISTS public.permissions CASCADE;
DROP TABLE IF EXISTS public.user_permissions CASCADE;
DROP TABLE IF EXISTS public.menu_permissions CASCADE;
DROP TABLE IF EXISTS public.v_role_id CASCADE;

-- Set REPLICA IDENTITY to FULL for tables that will be updated
ALTER TABLE public.attention_products REPLICA IDENTITY FULL;
ALTER TABLE public.roles REPLICA IDENTITY FULL;
ALTER TABLE public.appointments REPLICA IDENTITY FULL;
ALTER TABLE public.appointment_products REPLICA IDENTITY FULL;
ALTER TABLE public.appointment_sessions REPLICA IDENTITY FULL;
ALTER TABLE public.services REPLICA IDENTITY FULL;
ALTER TABLE public.service_categories REPLICA IDENTITY FULL;
ALTER TABLE public.appointment_extra_services REPLICA IDENTITY FULL;
ALTER TABLE public.product_category_assignments REPLICA IDENTITY FULL;
ALTER TABLE public.client_whatsapp_queue REPLICA IDENTITY FULL;
ALTER TABLE public.supplier_products REPLICA IDENTITY FULL;
ALTER TABLE public.purchase_item_receptions REPLICA IDENTITY FULL;
ALTER TABLE public.audit_logs REPLICA IDENTITY FULL;
ALTER TABLE public.equipment_assignments REPLICA IDENTITY FULL;
ALTER TABLE public.product_brands REPLICA IDENTITY FULL;
ALTER TABLE public.equipment_maintenance_history REPLICA IDENTITY FULL;
ALTER TABLE public.service_user_commissions REPLICA IDENTITY FULL;
ALTER TABLE public.product_user_commissions REPLICA IDENTITY FULL;
ALTER TABLE public.performance_metrics REPLICA IDENTITY FULL;
ALTER TABLE public.extra_service_sessions REPLICA IDENTITY FULL;
ALTER TABLE public.schedule_templates REPLICA IDENTITY FULL;
ALTER TABLE public.user_schedules REPLICA IDENTITY FULL;
ALTER TABLE public.service_sessions REPLICA IDENTITY FULL;
ALTER TABLE public.tax_types REPLICA IDENTITY FULL;
ALTER TABLE public.product_transfer_receptions REPLICA IDENTITY FULL;
ALTER TABLE public.user_assignments REPLICA IDENTITY FULL;
ALTER TABLE public.invoice_items REPLICA IDENTITY FULL;
ALTER TABLE public.product_transfer_reception_items REPLICA IDENTITY FULL;
ALTER TABLE public.payment_methods REPLICA IDENTITY FULL;
ALTER TABLE public.api_request_metrics REPLICA IDENTITY FULL;
ALTER TABLE public.invoices REPLICA IDENTITY FULL;
ALTER TABLE public.invoice_item_taxes REPLICA IDENTITY FULL;
ALTER TABLE public.attention_payments REPLICA IDENTITY FULL;
ALTER TABLE public.attention_service_evidences REPLICA IDENTITY FULL;
ALTER TABLE public.branch_status_history REPLICA IDENTITY FULL;
ALTER TABLE public.products REPLICA IDENTITY FULL;
ALTER TABLE public.branch_services REPLICA IDENTITY FULL;
ALTER TABLE public.service_tax_types REPLICA IDENTITY FULL;
ALTER TABLE public.attention_payment_evidences REPLICA IDENTITY FULL;
ALTER TABLE public.product_categories REPLICA IDENTITY FULL;
ALTER TABLE public.branch_products REPLICA IDENTITY FULL;
ALTER TABLE public.commission_payment_evidences REPLICA IDENTITY FULL;
ALTER TABLE public.user_time_off REPLICA IDENTITY FULL;
ALTER TABLE public.product_tax_types REPLICA IDENTITY FULL;
ALTER TABLE public.purchases REPLICA IDENTITY FULL;
ALTER TABLE public.attention_services REPLICA IDENTITY FULL;
ALTER TABLE public.tenant_client_settings REPLICA IDENTITY FULL;
ALTER TABLE public.purchase_items REPLICA IDENTITY FULL;
ALTER TABLE public.client_document_templates REPLICA IDENTITY FULL;
ALTER TABLE public.client_document_instances REPLICA IDENTITY FULL;
ALTER TABLE public.client_consent_records REPLICA IDENTITY FULL;
ALTER TABLE public.client_branches REPLICA IDENTITY FULL;
ALTER TABLE public.branch_combo_item_prices REPLICA IDENTITY FULL;
ALTER TABLE public.product_transfers REPLICA IDENTITY FULL;
ALTER TABLE public.equipment REPLICA IDENTITY FULL;
ALTER TABLE public.combo_items REPLICA IDENTITY FULL;
ALTER TABLE public.equipment_types REPLICA IDENTITY FULL;
ALTER TABLE public.combos REPLICA IDENTITY FULL;
ALTER TABLE public.clients REPLICA IDENTITY FULL;
ALTER TABLE public.branch_combos REPLICA IDENTITY FULL;
ALTER TABLE public.media_playlists REPLICA IDENTITY FULL;
ALTER TABLE public.turns REPLICA IDENTITY FULL;
ALTER TABLE public.playlist_items REPLICA IDENTITY FULL;
ALTER TABLE public.equipment_brands REPLICA IDENTITY FULL;
ALTER TABLE public.tv_displays REPLICA IDENTITY FULL;
ALTER TABLE public.client_addresses REPLICA IDENTITY FULL;
ALTER TABLE public.client_contacts REPLICA IDENTITY FULL;
ALTER TABLE public.product_transfer_items REPLICA IDENTITY FULL;
ALTER TABLE public.attention_combos REPLICA IDENTITY FULL;
ALTER TABLE public.attention_service_status_history REPLICA IDENTITY FULL;
ALTER TABLE public.units_of_measure REPLICA IDENTITY FULL;
ALTER TABLE public.product_images REPLICA IDENTITY FULL;
ALTER TABLE public.branch_playback_state REPLICA IDENTITY FULL;
ALTER TABLE public.rescheduled_attentions REPLICA IDENTITY FULL;
ALTER TABLE public.branch_social_networks REPLICA IDENTITY FULL;
ALTER TABLE public.chatter_comments REPLICA IDENTITY FULL;
ALTER TABLE public.chatter_attachments REPLICA IDENTITY FULL;
ALTER TABLE public.product_movements REPLICA IDENTITY FULL;
ALTER TABLE public.document_sequences REPLICA IDENTITY FULL;
ALTER TABLE public.sales REPLICA IDENTITY FULL;
ALTER TABLE public.sales_items REPLICA IDENTITY FULL;
ALTER TABLE public.suppliers REPLICA IDENTITY FULL;
ALTER TABLE public.satisfaction_surveys REPLICA IDENTITY FULL;
ALTER TABLE public.client_email_queue REPLICA IDENTITY FULL;
ALTER TABLE public.payslip_commissions REPLICA IDENTITY FULL;
ALTER TABLE public.client_professionals REPLICA IDENTITY FULL;
ALTER TABLE public.client_commercials REPLICA IDENTITY FULL;
ALTER TABLE public.satisfaction_survey_ratings REPLICA IDENTITY FULL;
ALTER TABLE public.earned_commissions REPLICA IDENTITY FULL;
ALTER TABLE public.payslips REPLICA IDENTITY FULL;
ALTER TABLE public.attentions REPLICA IDENTITY FULL;
ALTER TABLE public.notifications REPLICA IDENTITY FULL;
ALTER TABLE public.supplier_addresses REPLICA IDENTITY FULL;
ALTER TABLE public.supplier_contacts REPLICA IDENTITY FULL;
ALTER TABLE public.service_images REPLICA IDENTITY FULL;
ALTER TABLE public.document_types REPLICA IDENTITY FULL;
ALTER TABLE public.contact_types REPLICA IDENTITY FULL;
ALTER TABLE public.signed_consents REPLICA IDENTITY FULL;
ALTER TABLE public.treatment_sessions REPLICA IDENTITY FULL;
ALTER TABLE public.treatments REPLICA IDENTITY FULL;
ALTER TABLE public.client_treatments REPLICA IDENTITY FULL;
ALTER TABLE public.treatment_session_items REPLICA IDENTITY FULL;
ALTER TABLE public.client_treatment_sessions REPLICA IDENTITY FULL;
ALTER TABLE public.informed_consent_templates REPLICA IDENTITY FULL;
ALTER TABLE public.consent_signatures REPLICA IDENTITY FULL;
ALTER TABLE public.branch_photos REPLICA IDENTITY FULL;
ALTER TABLE public.treatment_categories REPLICA IDENTITY FULL;
ALTER TABLE public.staff_gallery_items REPLICA IDENTITY FULL;
ALTER TABLE public.treatment_category_assignments REPLICA IDENTITY FULL;
ALTER TABLE public.client_treatment_session_items REPLICA IDENTITY FULL;
ALTER TABLE public.treatment_images REPLICA IDENTITY FULL;
ALTER TABLE public.combo_images REPLICA IDENTITY FULL;
ALTER TABLE public.expenses REPLICA IDENTITY FULL;
ALTER TABLE public.recurring_expenses REPLICA IDENTITY FULL;
ALTER TABLE public.absence_types REPLICA IDENTITY FULL;
ALTER TABLE public.expense_providers REPLICA IDENTITY FULL;
ALTER TABLE public.expense_provider_contacts REPLICA IDENTITY FULL;
ALTER TABLE public.expense_provider_addresses REPLICA IDENTITY FULL;

-- Backfill platform_id for various tables based on their relationships

UPDATE public.roles
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.roles.tenant_id = t.id AND public.roles.platform_id IS NULL;

-- Tables with direct or indirect link to tenants.platform_id (most tables)
UPDATE public.attention_products
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.attention_products.tenant_id = t.id AND public.attention_products.platform_id IS NULL;

UPDATE public.appointments
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.appointments.tenant_id = t.id AND public.appointments.platform_id IS NULL;

UPDATE public.appointment_products
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.appointment_products.tenant_id = t.id AND public.appointment_products.platform_id IS NULL;

UPDATE public.appointment_sessions
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.appointment_sessions.tenant_id = t.id AND public.appointment_sessions.platform_id IS NULL;

UPDATE public.services
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.services.tenant_id = t.id AND public.services.platform_id IS NULL;

UPDATE public.service_categories
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.service_categories.tenant_id = t.id AND public.service_categories.platform_id IS NULL;

UPDATE public.appointment_extra_services
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.appointment_extra_services.tenant_id = t.id AND public.appointment_extra_services.platform_id IS NULL;

UPDATE public.product_category_assignments
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.product_category_assignments.tenant_id = t.id AND public.product_category_assignments.platform_id IS NULL;

UPDATE public.client_whatsapp_queue
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.client_whatsapp_queue.tenant_id = t.id AND public.client_whatsapp_queue.platform_id IS NULL;

UPDATE public.supplier_products
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.supplier_products.tenant_id = t.id AND public.supplier_products.platform_id IS NULL;

UPDATE public.purchase_item_receptions
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.purchase_item_receptions.tenant_id = t.id AND public.purchase_item_receptions.platform_id IS NULL;

UPDATE public.audit_logs
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.audit_logs.tenant_id = t.id AND public.audit_logs.platform_id IS NULL;

UPDATE public.equipment_assignments
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.equipment_assignments.tenant_id = t.id AND public.equipment_assignments.platform_id IS NULL;

UPDATE public.product_brands
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.product_brands.tenant_id = t.id AND public.product_brands.platform_id IS NULL;

UPDATE public.equipment_maintenance_history
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.equipment_maintenance_history.tenant_id = t.id AND public.equipment_maintenance_history.platform_id IS NULL;

UPDATE public.service_user_commissions
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.service_user_commissions.tenant_id = t.id AND public.service_user_commissions.platform_id IS NULL;

UPDATE public.product_user_commissions
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.product_user_commissions.tenant_id = t.id AND public.product_user_commissions.platform_id IS NULL;

UPDATE public.performance_metrics
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.performance_metrics.tenant_id = t.id AND public.performance_metrics.platform_id IS NULL;

UPDATE public.extra_service_sessions
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.extra_service_sessions.tenant_id = t.id AND public.extra_service_sessions.platform_id IS NULL;

UPDATE public.schedule_templates
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.schedule_templates.tenant_id = t.id AND public.schedule_templates.platform_id IS NULL;

UPDATE public.user_schedules
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.user_schedules.tenant_id = t.id AND public.user_schedules.platform_id IS NULL;

UPDATE public.service_sessions
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.service_sessions.tenant_id = t.id AND public.service_sessions.platform_id IS NULL;

UPDATE public.tax_types
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.tax_types.tenant_id = t.id AND public.tax_types.platform_id IS NULL;

UPDATE public.product_transfer_receptions
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.product_transfer_receptions.tenant_id = t.id AND public.product_transfer_receptions.platform_id IS NULL;

UPDATE public.user_assignments
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.user_assignments.tenant_id = t.id AND public.user_assignments.platform_id IS NULL;

UPDATE public.invoice_items
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.invoice_items.tenant_id = t.id AND public.invoice_items.platform_id IS NULL;

UPDATE public.product_transfer_reception_items
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.product_transfer_reception_items.tenant_id = t.id AND public.product_transfer_reception_items.platform_id IS NULL;

UPDATE public.payment_methods
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.payment_methods.tenant_id = t.id AND public.payment_methods.platform_id IS NULL;

UPDATE public.api_request_metrics
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.api_request_metrics.tenant_id = t.id AND public.api_request_metrics.platform_id IS NULL;

UPDATE public.invoices
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.invoices.tenant_id = t.id AND public.invoices.platform_id IS NULL;

UPDATE public.invoice_item_taxes
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.invoice_item_taxes.tenant_id = t.id AND public.invoice_item_taxes.platform_id IS NULL;

UPDATE public.attention_payments
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.attention_payments.tenant_id = t.id AND public.attention_payments.platform_id IS NULL;

UPDATE public.attention_service_evidences
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.attention_service_evidences.tenant_id = t.id AND public.attention_service_evidences.platform_id IS NULL;

UPDATE public.branch_status_history
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.branch_status_history.tenant_id = t.id AND public.branch_status_history.platform_id IS NULL;

UPDATE public.products
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.products.tenant_id = t.id AND public.products.platform_id IS NULL;

UPDATE public.branch_services
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.branch_services.tenant_id = t.id AND public.branch_services.platform_id IS NULL;

UPDATE public.service_tax_types
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.service_tax_types.tenant_id = t.id AND public.service_tax_types.platform_id IS NULL;

UPDATE public.attention_payment_evidences
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.attention_payment_evidences.tenant_id = t.id AND public.attention_payment_evidences.platform_id IS NULL;

UPDATE public.product_categories
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.product_categories.tenant_id = t.id AND public.product_categories.platform_id IS NULL;

UPDATE public.branch_products
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.branch_products.tenant_id = t.id AND public.branch_products.platform_id IS NULL;

UPDATE public.commission_payment_evidences
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.commission_payment_evidences.tenant_id = t.id AND public.commission_payment_evidences.platform_id IS NULL;

UPDATE public.user_time_off
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.user_time_off.tenant_id = t.id AND public.user_time_off.platform_id IS NULL;

UPDATE public.product_tax_types
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.product_tax_types.tenant_id = t.id AND public.product_tax_types.platform_id IS NULL;

UPDATE public.purchases
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.purchases.tenant_id = t.id AND public.purchases.platform_id IS NULL;

UPDATE public.attention_services
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.attention_services.tenant_id = t.id AND public.attention_services.platform_id IS NULL;

UPDATE public.tenant_client_settings
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.tenant_client_settings.tenant_id = t.id AND public.tenant_client_settings.platform_id IS NULL;

UPDATE public.purchase_items
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.purchase_items.tenant_id = t.id AND public.purchase_items.platform_id IS NULL;

UPDATE public.client_document_templates
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.client_document_templates.tenant_id = t.id AND public.client_document_templates.platform_id IS NULL;

UPDATE public.client_document_instances
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.client_document_instances.tenant_id = t.id AND public.client_document_instances.platform_id IS NULL;

UPDATE public.client_consent_records
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.client_consent_records.tenant_id = t.id AND public.client_consent_records.platform_id IS NULL;

UPDATE public.client_branches
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.client_branches.tenant_id = t.id AND public.client_branches.platform_id IS NULL;

UPDATE public.branch_combo_item_prices
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.branch_combo_item_prices.tenant_id = t.id AND public.branch_combo_item_prices.platform_id IS NULL;

UPDATE public.product_transfers
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.product_transfers.tenant_id = t.id AND public.product_transfers.platform_id IS NULL;

UPDATE public.equipment
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.equipment.tenant_id = t.id AND public.equipment.platform_id IS NULL;

UPDATE public.combo_items
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.combo_items.tenant_id = t.id AND public.combo_items.platform_id IS NULL;

UPDATE public.equipment_types
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.equipment_types.tenant_id = t.id AND public.equipment_types.platform_id IS NULL;

UPDATE public.combos
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.combos.tenant_id = t.id AND public.combos.platform_id IS NULL;

UPDATE public.clients
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.clients.tenant_id = t.id AND public.clients.platform_id IS NULL;

UPDATE public.branch_combos
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.branch_combos.tenant_id = t.id AND public.branch_combos.platform_id IS NULL;

UPDATE public.media_playlists
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.media_playlists.tenant_id = t.id AND public.media_playlists.platform_id IS NULL;

UPDATE public.turns
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.turns.tenant_id = t.id AND public.turns.platform_id IS NULL;

UPDATE public.playlist_items
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.playlist_items.tenant_id = t.id AND public.playlist_items.platform_id IS NULL;

UPDATE public.equipment_brands
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.equipment_brands.tenant_id = t.id AND public.equipment_brands.platform_id IS NULL;

UPDATE public.tv_displays
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.tv_displays.tenant_id = t.id AND public.tv_displays.platform_id IS NULL;

UPDATE public.client_addresses
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.client_addresses.tenant_id = t.id AND public.client_addresses.platform_id IS NULL;

UPDATE public.client_contacts
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.client_contacts.tenant_id = t.id AND public.client_contacts.platform_id IS NULL;

UPDATE public.attention_combos
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.attention_combos.tenant_id = t.id AND public.attention_combos.platform_id IS NULL;

UPDATE public.attention_service_status_history
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.attention_service_status_history.tenant_id = t.id AND public.attention_service_status_history.platform_id IS NULL;

UPDATE public.units_of_measure
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.units_of_measure.tenant_id = t.id AND public.units_of_measure.platform_id IS NULL;

UPDATE public.product_images
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.product_images.tenant_id = t.id AND public.product_images.platform_id IS NULL;

UPDATE public.branch_playback_state
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.branch_playback_state.tenant_id = t.id AND public.branch_playback_state.platform_id IS NULL;

UPDATE public.rescheduled_attentions
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.rescheduled_attentions.tenant_id = t.id AND public.rescheduled_attentions.platform_id IS NULL;

UPDATE public.branch_social_networks
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.branch_social_networks.tenant_id = t.id AND public.branch_social_networks.platform_id IS NULL;

UPDATE public.chatter_comments
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.chatter_comments.tenant_id = t.id AND public.chatter_comments.platform_id IS NULL;

UPDATE public.chatter_attachments
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.chatter_attachments.tenant_id = t.id AND public.chatter_attachments.platform_id IS NULL;

UPDATE public.product_movements
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.product_movements.tenant_id = t.id AND public.product_movements.platform_id IS NULL;

UPDATE public.document_sequences
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.document_sequences.tenant_id = t.id AND public.document_sequences.platform_id IS NULL;

UPDATE public.sales
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.sales.tenant_id = t.id AND public.sales.platform_id IS NULL;

UPDATE public.sales_items
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.sales_items.tenant_id = t.id AND public.sales_items.platform_id IS NULL;

UPDATE public.suppliers
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.suppliers.tenant_id = t.id AND public.suppliers.platform_id IS NULL;

UPDATE public.satisfaction_surveys
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.satisfaction_surveys.tenant_id = t.id AND public.satisfaction_surveys.platform_id IS NULL;

UPDATE public.client_email_queue
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.client_email_queue.tenant_id = t.id AND public.client_email_queue.platform_id IS NULL;

UPDATE public.client_professionals
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.client_professionals.tenant_id = t.id AND public.client_professionals.platform_id IS NULL;

UPDATE public.client_commercials
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.client_commercials.tenant_id = t.id AND public.client_commercials.platform_id IS NULL;

UPDATE public.satisfaction_survey_ratings
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.satisfaction_survey_ratings.tenant_id = t.id AND public.satisfaction_survey_ratings.platform_id IS NULL;

UPDATE public.earned_commissions
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.earned_commissions.tenant_id = t.id AND public.earned_commissions.platform_id IS NULL;

UPDATE public.payslips
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.payslips.tenant_id = t.id AND public.payslips.platform_id IS NULL;

UPDATE public.attentions
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.attentions.tenant_id = t.id AND public.attentions.platform_id IS NULL;

UPDATE public.notifications
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.notifications.tenant_id = t.id AND public.notifications.platform_id IS NULL;

UPDATE public.supplier_addresses
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.supplier_addresses.tenant_id = t.id AND public.supplier_addresses.platform_id IS NULL;

UPDATE public.supplier_contacts
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.supplier_contacts.tenant_id = t.id AND public.supplier_contacts.platform_id IS NULL;

UPDATE public.service_images
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.service_images.tenant_id = t.id AND public.service_images.platform_id IS NULL;

UPDATE public.document_types
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.document_types.tenant_id = t.id AND public.document_types.platform_id IS NULL;

UPDATE public.contact_types
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.contact_types.tenant_id = t.id AND public.contact_types.platform_id IS NULL;

UPDATE public.signed_consents
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.signed_consents.tenant_id = t.id AND public.signed_consents.platform_id IS NULL;

UPDATE public.treatment_sessions
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.treatment_sessions.tenant_id = t.id AND public.treatment_sessions.platform_id IS NULL;

UPDATE public.treatments
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.treatments.tenant_id = t.id AND public.treatments.platform_id IS NULL;

UPDATE public.client_treatments
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.client_treatments.tenant_id = t.id AND public.client_treatments.platform_id IS NULL;

UPDATE public.treatment_session_items
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.treatment_session_items.tenant_id = t.id AND public.treatment_session_items.platform_id IS NULL;

UPDATE public.client_treatment_sessions
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.client_treatment_sessions.tenant_id = t.id AND public.client_treatment_sessions.platform_id IS NULL;

UPDATE public.informed_consent_templates
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.informed_consent_templates.tenant_id = t.id AND public.informed_consent_templates.platform_id IS NULL;

UPDATE public.consent_signatures
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.consent_signatures.tenant_id = t.id AND public.consent_signatures.platform_id IS NULL;

UPDATE public.branch_photos
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.branch_photos.tenant_id = t.id AND public.branch_photos.platform_id IS NULL;

UPDATE public.treatment_categories
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.treatment_categories.tenant_id = t.id AND public.treatment_categories.platform_id IS NULL;

UPDATE public.staff_gallery_items
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.staff_gallery_items.tenant_id = t.id AND public.staff_gallery_items.platform_id IS NULL;

UPDATE public.treatment_category_assignments
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.treatment_category_assignments.tenant_id = t.id AND public.treatment_category_assignments.platform_id IS NULL;

UPDATE public.client_treatment_session_items
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.client_treatment_session_items.tenant_id = t.id AND public.client_treatment_session_items.platform_id IS NULL;

UPDATE public.treatment_images
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.treatment_images.tenant_id = t.id AND public.treatment_images.platform_id IS NULL;

UPDATE public.combo_images
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.combo_images.tenant_id = t.id AND public.combo_images.platform_id IS NULL;

UPDATE public.expenses
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.expenses.tenant_id = t.id AND public.expenses.platform_id IS NULL;

UPDATE public.recurring_expenses
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.recurring_expenses.tenant_id = t.id AND public.recurring_expenses.platform_id IS NULL;

UPDATE public.absence_types
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.absence_types.tenant_id = t.id AND public.absence_types.platform_id IS NULL;

UPDATE public.expense_providers
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.expense_providers.tenant_id = t.id AND public.expense_providers.platform_id IS NULL;

UPDATE public.expense_provider_contacts
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.expense_provider_contacts.tenant_id = t.id AND public.expense_provider_contacts.platform_id IS NULL;

UPDATE public.expense_provider_addresses
SET platform_id = t.platform_id
FROM public.tenants t
WHERE public.expense_provider_addresses.tenant_id = t.id AND public.expense_provider_addresses.platform_id IS NULL;