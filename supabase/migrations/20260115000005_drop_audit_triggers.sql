-- This migration drops all triggers that call the generic 'audit_trigger_function'.
-- This is done to disable the old audit logging mechanism.

DROP TRIGGER IF EXISTS audit_absence_types_changes ON public.absence_types;
DROP TRIGGER IF EXISTS audit_attention_payment_evidences_changes ON public.attention_payment_evidences;
DROP TRIGGER IF EXISTS audit_attention_products_changes ON public.attention_products;
DROP TRIGGER IF EXISTS audit_attention_service_evidences_changes ON public.attention_service_evidences;
DROP TRIGGER IF EXISTS audit_attention_services_changes ON public.attention_services;
DROP TRIGGER IF EXISTS audit_attentions_changes ON public.attentions;
DROP TRIGGER IF EXISTS audit_branch_products_changes ON public.branch_products;
DROP TRIGGER IF EXISTS audit_branch_services_changes ON public.branch_services;
DROP TRIGGER IF EXISTS audit_branches_changes ON public.branches;
DROP TRIGGER IF EXISTS audit_client_branches_changes ON public.client_branches;
DROP TRIGGER IF EXISTS audit_clients_changes ON public.clients;
DROP TRIGGER IF EXISTS audit_changes_on_combo_items ON public.combo_items;
DROP TRIGGER IF EXISTS audit_changes_on_combos ON public.combos;
DROP TRIGGER IF EXISTS audit_commission_payment_evidences_changes ON public.commission_payment_evidences;
DROP TRIGGER IF EXISTS audit_consent_signatures_changes ON public.consent_signatures;
DROP TRIGGER IF EXISTS audit_changes_on_expense_providers ON public.expense_providers;
DROP TRIGGER IF EXISTS audit_changes_on_expenses ON public.expenses;
DROP TRIGGER IF EXISTS audit_extra_service_sessions_changes ON public.extra_service_sessions;
DROP TRIGGER IF EXISTS audit_brands_changes ON public.product_brands;
DROP TRIGGER IF EXISTS audit_product_user_commissions_changes ON public.product_user_commissions;
DROP TRIGGER IF EXISTS audit_changes_on_products ON public.products;
DROP TRIGGER IF EXISTS audit_changes_on_recurring_expenses ON public.recurring_expenses;
DROP TRIGGER IF EXISTS audit_satisfaction_survey_ratings_changes ON public.satisfaction_survey_ratings;
DROP TRIGGER IF EXISTS audit_satisfaction_surveys_changes ON public.satisfaction_surveys;
DROP TRIGGER IF EXISTS audit_schedule_templates_changes ON public.schedule_templates;
DROP TRIGGER IF EXISTS audit_service_categories_changes ON public.service_categories;
DROP TRIGGER IF EXISTS audit_service_sessions_changes ON public.service_sessions;
DROP TRIGGER IF EXISTS audit_service_user_commissions_changes ON public.service_user_commissions;
DROP TRIGGER IF EXISTS audit_changes_on_services ON public.services;
DROP TRIGGER IF EXISTS audit_supplier_products_changes ON public.supplier_products;
DROP TRIGGER IF EXISTS audit_changes_on_suppliers ON public.suppliers;
DROP TRIGGER IF EXISTS audit_tenants_changes ON public.tenants;
DROP TRIGGER IF EXISTS audit_user_schedules_changes ON public.user_schedules;
DROP TRIGGER IF EXISTS audit_user_time_off_changes ON public.user_time_off;
