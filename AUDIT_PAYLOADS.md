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

## 2.b Segunda ronda (decisiones del equipo) ✅
- **Imágenes de proyecto (TattooSuite)**: los proyectos comparten tabla con los tratamientos, así que `get/associate/delete/set_primary_project_image` ahora son alias de las RPC `*_treatment_image(s)` (`projectId` → `p_treatment_id`).
- **Precio de combo por sucursal**: el precio vive a nivel de ítem (`branch_combo_item_prices`) para repartir comisiones. Se implementó `bulk_update_branch_combo_prices` (`{branchId, updates:[{combo_id, selling_price}]}`): lee los ítems con `get_combo_branch_details` y **reparte el nuevo total proporcionalmente** entre los ítems (ajuste de redondeo en el último ítem de cantidad 1; si el total actual es 0, reparto igual por unidad) llamando a `update_combo_branch_prices`. ⚠️ Supuesto: reparto proporcional; si se prefiere otra regla, cambiar solo ese `case`.
- **Encuesta**: `public-actions` ahora tiene `GET_SURVEY_DETAILS_BY_TOKEN` (todo se resuelve desde `survey_token` → `attention_id`: cliente, sucursal, servicios, profesionales; el tenant se lee de Core). `logo_base64` y `avatar_base64` van vacíos (la UI usa su imagen por defecto / iniciales).
- **Pago al volver de la pasarela**: `update-attention-payment-status` existe, pero **solo consulta** el estado de los pagos de la atención (no confía en el retorno del navegador para marcarlos pagados). `PaymentSuccess` muestra "Pago en verificación" si aún hay pagos pendientes.
- **Superadmin en Services → Core**: en `superadmin-actions` las acciones de integraciones, `platform_assignments`, `investor_platform_shares`, `vendor_*`, `roles` de plataforma, `get_platform_level_assignments`, `get_api_health_stats` y `api_request_metrics` ahora usan el cliente de Core; `get_tenant_users` usa los nombres de parámetro nuevos. Lo que es de auth/Services (`auth.admin`, `set_system_owner`, `update_user_name`, `user_assignments`) se queda en Services.
- **Funciones llamadas desde el front que no existían en Services**: `upsert_tenant_integration` (existe en Core) ahora se invoca vía la nueva acción `save_tenant_integration` de `tenant-actions` (usa tenant/plataforma/rol del JWT); se eliminaron los hooks muertos `useApiHealthStats`, `useUsageStatistics`, `useTenantAccessLogs` (sin consumidores y sin RPC en ninguna BD).
- `google-oauth-token` (Services) ahora guarda la integración en Core con `platform_id`.

## 3. ⚠️ Pendiente (requiere decisión o mayor alcance)

1. **Pago de atenciones con Wompi (flujo completo)**: `process_attention_payment` invoca `wompi-generate-checkout` desde Services, pero esa función solo existe en Core y es de suscripciones (exige `planId`, usa la integración del dueño de plataforma) y el webhook de Core no procesa pagos de atenciones (la acción `update_attention_payment_status` que se le pasa no existe). Falta diseñar este flujo; `WompiCheckout.tsx` (monto libre) tampoco envía `userId/planId`.
2. **Core**: `core-actions` llama RPC que solo existen en Services (`set_system_owner`, `get_tenant_users`, `update_user_name`) y `get_infrastructure_metrics` llama a `non_existent_ping_function`; `whatsapp-webhook` llama `queue_client_whatsapp` con nombres de parámetro viejos; insert en `api_request_metrics` sin `tenant_id/platform_id` (L2674).
3. `PlanPriceForm` llama `schedule_new_price` (el backend tiene `schedule_new_tariff` con otro payload).
4. Edge functions de Services que son copias legacy de Core y consultan tablas inexistentes en Services: `google-drive-refresh-token`, `process-email-queue`, `send-system-email`, `process-billing-cycles` (+ `get_price_for_tenant_asset` sin `p_platform_id`), `update-exchange-rates`, `proxy-google-drive-image`; la RPC `send_electronic_document` lee `public.tenant_integrations`. Candidatas a limpiarse de Services una vez confirmado que Core las cubre.
5. Payloads dinámicos sin verificar a mano: `create_product_transfer(_request)`, `update_product_transfer_status`, `create/update_supplier`, `create-expense-provider-contact` (claves del backend coherentes).
6. Seguridad: varias RPC `SECURITY DEFINER` (`cancel_attention_and_notify`, `confirm_attention`, `end_service`, …) no validan tenant; al quitar `p_tenant_id` el aislamiento depende solo del `id` recibido.
7. `TASKS_PAYLOADS.md`: A2, A3, A4, B1–B4, B6 resueltas; B5 parcialmente (ver punto 1); C1 y C3 abiertas.

## 4. Para probar tras desplegar
Dashboard (stats + citas de hoy), cancelar/confirmar cita, iniciar/finalizar servicio, subida de evidencias/logo/fotos (Drive), notificaciones internas, galería de personal, compras (estado de pago/recepción), transferencias (rechazar), equipos (crear), invitar/asignar usuarios, archivar sucursal, imágenes de servicio, tipos de contacto de proveedor, eliminar producto/servicio/proveedor.
