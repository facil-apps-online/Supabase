# Auditoría de contratos Frontend ⇄ Backend (Glamtica / TattooSuite ⇄ Supabase)

Fecha: 2026-10-01 · Rama: `claude/glamptica-tattoo-supabase-y1tums` (los 3 repos)

## Método
Se construyó un extractor automático (no versionado) que cruzó:
- **Frontends**: ~836 llamadas (`callTenantAction`, `fetchTenantAction`, `invokeTenantAction`, `functions.invoke`, `.rpc`, `mutate({action})`), con los tipos de payload resueltos con el compilador de TypeScript.
- **Edge functions**: todos los `case` de `tenant-actions`, `user-actions`, `public-actions`, `superadmin-actions` y `core-actions` (claves de payload leídas, RPC llamadas, tablas tocadas).
- **SQL**: catálogo de funciones (firmas) y de tablas/columnas reconstruido con `schema.sql` + migraciones (Services y Core).

Cada hallazgo marcado ✅ se corrigió en esta rama; ⚠️ queda **pendiente** con diagnóstico (requiere decisión o es de mayor alcance).

---

## 1. Corregido en el backend (Supabase / Services)

### 1.1 Llamadas RPC que no coincidían con la firma SQL (fallaban con PGRST202) ✅
Las funciones SQL ya no aceptan `p_tenant_id` (o aceptan `p_platform_id`) pero la edge function seguía enviando otros parámetros.

| Acción (tenant-actions) | RPC | Problema → arreglo |
|---|---|---|
| `get-dashboard-stats`, `get-today-attentions` | `get_dashboard_stats`, `get_today_attentions` | faltaba `p_platform_id` (obligatorio). Ahora se envía y `p_tenant_id` sale del JWT (antes venía del payload del cliente) |
| `cancel_attention` | `cancel_attention_and_notify` | sobraba `p_tenant_id` |
| `confirm_attention` | `confirm_attention` | sobraba `p_tenant_id` |
| `start_attention_service` / `finish_attention_service` | `start_service` / `end_service` | `start_service`: sobraba `p_tenant_id`; `end_service` solo acepta `p_attention_service_id` |
| `update_purchase_payment_status`, `get_purchase_reception_details` | idem | sobraba `p_tenant_id` |
| `update_playlist_items_order` (TV) | idem | sobraba `p_tenant_id` |
| `create_equipment` | idem | sobraba `p_tenant_id` |
| `process_attention_payment` | `generate_invoice_for_attention` | sobraba `p_tenant_id` |
| `get_payslip_commission_details` | `get_payslip_details` | sobraba `p_tenant_id` |
| `reject_product_transfer` | idem | faltaba `p_user_id` |
| helper de notificaciones (6 usos: menciones, citas, comisiones, liquidaciones) | `create_notification` | faltaba `p_platform_id` → **ninguna notificación interna se creaba** (el error se tragaba) |
| `get_staff_gallery` / `update_staff_gallery` | helpers `_getStaffGallery/_updateStaffGallery` | se les pasaba `platformId` como 3.er argumento pero la firma no lo tenía → `staffId` recibía el platformId. Además `update_staff_gallery_settings` exigía `p_platform_id` |
| métrica al final de cada request | `log_api_metric` (Core) | sobraba `p_platform_id` → las métricas nunca se registraban |
| `user-actions: update-assignments` | `update_user_assignments` | faltaba `p_platform_id` (se toma del payload o de `tenants.platform_id`) |
| `public-actions: public_get_current_turns` | `get_current_turns_for_branch` | sobraba `p_platform_id` |

### 1.2 Acciones que el frontend invocaba y no existían ✅
`associate_service_image`, `delete_service_image`, `set_primary_service_image`, `update_service_images_order` (las RPC SQL ya existían), `get_notification_settings`, `delete_master_product`, `delete_master_service`, `delete_supplier`.

### 1.3 Tablas de Core consultadas en la base de Services ✅
Estas tablas fueron movidas a Core (`20260113000002_drop_core_tables_from_services.sql`); ahora se consultan con `coreSupabase`:
`get_regional_settings_data` (`languages`, `currencies`), verificación de integración Wompi en `process_attention_payment` (`tenant_integrations`), `insert_system_alert` (`system_alerts`).

### 1.4 Google Drive en Services (estaba completamente roto) ✅
`supabase/functions/google-drive-upload` tenía código truncado (`// ... rest of the code ...`, variables sin definir) y leía `tenants/platforms/tenant_integrations` de Services, donde ya no existen. `google-drive-delete` igual. Ahora ambas **conservan el contrato histórico** (`tenantId, fileBase64, uploadContext, contextId…`) y delegan la subida/borrado en las funciones de Core; los registros en BD (evidencias, pagos, imágenes, fotos de sucursal, chatter, firmas de consentimiento, logo) se siguen haciendo en Services (ahora también con `platform_id`). Así quedan operativos los ~14 call-sites del front sin tocarlos. Las carpetas en Drive se crean como `<tenantId>/<uploadContext>/<contextId>`.
> Requiere que las edge functions de Services tengan `CORE_SUPABASE_URL` y `CORE_SUPABASE_SERVICE_ROLE_KEY` (ya las usa `getCoreSupabaseClient`) y que Core tenga desplegadas `google-drive-upload`/`google-drive-delete`.

### 1.5 Migración nueva ✅
`supabase/migrations/20260930000001_create_archive_branch.sql`: la RPC `archive_branch` (usada por `archive-branch`) no existía en ninguna migración.

## 2. Corregido en los frontends (Glamtica y TattooSuite, idéntico)
- `useSupplierContactTypes`: usaba 4 acciones inexistentes → ahora usa `get/create/update/delete_contact_type` (`applies_to: 'supplier'`, `is_for_supplier`).
- `useMonthlyPaidExpenses`: `get_current_month_paid_expenses` → `get_monthly_expense_summary` (devuelve `.paid`).
- `useEquipmentById`: `get_equipment_by_id` no existe → se filtra `get_equipment({showInactive:true})`.
- `useUpdateBranchCombo`: enviaba `is_active` suelto, el backend exige `updates: {...}`.
- `RegisterTvDialog` / `RegisterTvPage`: `authorize_tv_display` y `register_tv` exigen `p_platform_id`.
- Glamtica `AvatarUploader`: enviaba `integrationOwnerTenantId`; la función Core de borrado lee `integration_owner_tenant_id`.

---

## 3. ⚠️ Pendiente (requiere decisión o mayor alcance)

1. **TattooSuite – imágenes de proyecto** (`get/associate/delete/set_primary_project_image`): llaman RPC `*_project_image(s)` que no existen en SQL, ni hay tabla `project_images`. Falta definir el modelo (¿equivalente a `treatment_images`?).
2. **Precio de combo por sucursal** (`bulk_update_branch_combo_prices`, `selling_price` en `assign_combo_to_branch`/`useUpdateBranchCombo`): `branch_combos` no tiene columna de precio; el único mecanismo es `update_combo_branch_prices` (overrides por ítem). Decidir el modelo antes de implementar.
3. **Pagos**: `PaymentSuccess` invoca `update-attention-payment-status` (no existe; revisar si basta `process_attention_payment`). `WompiCheckout` no envía `userId/planId` que exige `generate_wompi_checkout`.
4. **Encuesta**: `public-actions` no tiene `GET_SURVEY_DETAILS_BY_TOKEN` (sí `SUBMIT_SURVEY`).
5. **Superadmin (Services `superadmin-actions`, 23 acciones llamadas por el front)**: las de integraciones, `platform_assignments`, `investor_*`, `vendor_*`, `api_request_metrics`, `payments` usan `tenantSupabase` sobre tablas que solo existen en Core (`get_tenant_integrations` además sin `p_platform_id`, `get_tenant_users` con nombres de parámetro viejos). El front debería llamar a `core-actions` (donde existen) o la función de Services proxear a Core. En Core hay RPC llamadas que solo existen en Services (`set_system_owner`, `get_tenant_users`, `update_user_name`) y `get_infrastructure_metrics` llama a `non_existent_ping_function`. `PlanPriceForm` llama `schedule_new_price` (el backend tiene `schedule_new_tariff`).
6. **RPC directas del front a Services que ya no existen ahí**: `upsert_tenant_integration` (ahora en Core y con `p_platform_id`), `get_api_health_stats` (Core), `get_usage_statistics`, `get_tenant_access_logs` (no existen en ninguna BD).
7. **Edge functions de Services que son copias legacy de Core** y consultan tablas inexistentes en Services: `google-oauth-token` (el callback OAuth del front la usa), `google-drive-refresh-token`, `process-email-queue`, `send-system-email`, `process-billing-cycles` (+ `get_price_for_tenant_asset` sin `p_platform_id`), `update-exchange-rates`, `proxy-google-drive-image`. Además `send_electronic_document` (SQL) lee `public.tenant_integrations` de Services.
8. **Core**: `whatsapp-webhook` llama `queue_client_whatsapp` con `p_client_id` (la firma usa `p_recipient_client_id`, `p_recipient_phone_number`); `api_request_metrics` insert sin `tenant_id/platform_id` (L2674 de `core-actions`).
9. Payloads dinámicos (variable sin tipo) sin verificar a mano: `create_product_transfer(_request)`, `update_product_transfer_status`, `create/update_supplier`, `create-expense-provider-contact` (las claves del backend parecen coherentes).
10. Seguridad (sin cambios): varias RPC `SECURITY DEFINER` (`cancel_attention_and_notify`, `confirm_attention`, `end_service`, …) no validan tenant; al quitar `p_tenant_id` el aislamiento depende solo del `id` recibido.
11. `TASKS_PAYLOADS.md` (10-ago): A2, A3, A4, B1, B2, B3 quedan resueltas con estos cambios; B4, B5, B6, C1–C3 siguen abiertas (puntos 2–4 arriba).

## 4. Para probar tras desplegar
Dashboard (stats + citas de hoy), cancelar/confirmar cita, iniciar/finalizar servicio, subida de evidencias/logo/fotos (Drive), notificaciones internas, galería de personal, compras (estado de pago/recepción), transferencias (rechazar), equipos (crear), invitar/asignar usuarios, archivar sucursal, imágenes de servicio, tipos de contacto de proveedor, eliminar producto/servicio/proveedor.
