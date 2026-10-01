# Tareas: Corrección de Payloads Backend/Frontend — Ecosistema Glamtica.app / TattooSuite.app

Generado a partir de una auditoría cruzada entre `tenant-actions/index.ts`, `user-actions/index.ts`, `public-actions/index.ts` (Servicios) y las ~160 invocaciones `supabase.functions.invoke(...)` de cada frontend, el 2026-08-10. Salvo que se indique lo contrario, cada bug existe **idéntico en Glamtica.app y TattooSuite.app** porque ambas apps comparten el mismo backend y prácticamente el mismo árbol de `src/hooks`.

Este archivo toca 3 repos: el backend (`c:\Desarrollos\supabase\...`), `c:\Desarrollos\Glamtica.app\...` y `c:\Desarrollos\TattooSuite.app\...`. Todas las rutas de este documento son absolutas — no asumas que quien ejecuta está parado en un repo en particular.

## Reglas generales

1. Ejecutar primero la **Sección A** (fixes de frontend, bajo riesgo, alta confianza) — son cambios de una o dos líneas verificados directamente contra el código fuente del backend.
2. Luego la **Sección B** (fixes de backend) — cada tarea trae el patrón exacto a mirar como referencia. Verificar que el patrón siga vigente (leer las líneas indicadas) antes de escribir código nuevo.
3. **NO ejecutar la Sección C sin antes consultar con el usuario.** Son casos donde el fix "obvio" podría ser la decisión de negocio equivocada — se necesita una respuesta humana, no una inferencia del modelo ejecutor.
4. La Sección D es opcional/cleanup, de menor prioridad.
5. Todos los fixes de esta lista deben aplicarse **por igual en `Glamtica.app` y `TattooSuite.app`** salvo que la tarea diga lo contrario (los hooks son casi siempre archivos idénticos en ambos repos, mismo path relativo).
6. Después de cada tarea de backend, si hay forma de probarlo (Supabase local, `supabase functions serve`), hacerlo. Si no, al menos verificar que el archivo compila/lintea sin errores de sintaxis.
7. Marcar `[ ]` → `[x]` al completar.

---

## SECCIÓN A — Fixes de frontend (el backend ya está bien; el frontend envía el payload equivocado)

### A1. [ ] Invitar/asignar usuario a un tenant envía IDs en vez de nombres

**Backend (correcto, no tocar):** `c:\Desarrollos\supabase\supabase\functions\user-actions\index.ts:445-451` — exige `email, tenantId, roleName, platformId` (y opcionalmente `branchName`). Nota que pide **nombres**, no IDs.

**Frontend roto:**
- `c:\Desarrollos\Glamtica.app\src\hooks\useInviteOrAssignUser.ts`
- `c:\Desarrollos\Glamtica.app\src\components\AddUserDialog.tsx` (líneas 156-172, función `handleFormSubmit`)
- Los mismos dos archivos en `TattooSuite.app` (mismo path relativo).

**Problema:** `AddUserDialog.tsx` arma el formulario con `roleId`/`branchId` (los IDs de los `<Select>`) y los manda tal cual al hook, que los reenvía al backend. El backend nunca recibe `roleName` → la llamada siempre falla con "Los campos email, tenantId, roleName y platformId son obligatorios."

**Referencia de la forma correcta:** `c:\Desarrollos\Glamtica.app\src\pages\RegisterTenant.tsx:326-327` ya arma el payload bien: `roleName: 'tenant_super_admin', branchName: 'Sucursal Principal'`.

**Fix:**
1. En `AddUserDialog.tsx`, dentro de `handleFormSubmit` (línea 156), antes de invocar la mutación, resolver los nombres a partir de los arrays `roles`/`branches` que el componente ya tiene disponibles (líneas 87-88, 238, 275):
   ```ts
   const selectedRoleObj = roles?.find(r => r.id === values.roleId);
   const selectedBranchObj = branches?.find(b => b.id === values.branchId);
   ```
2. Agregar `roleName: selectedRoleObj?.name` y (si no es super admin) `branchName: selectedBranchObj?.name` al objeto `submissionValues` antes de `.mutate(...)`.
3. En `useInviteOrAssignUser.ts`, actualizar la interfaz `InviteOrAssignUserFormValues` para incluir `roleName: string` y `branchName?: string` (se puede dejar `roleId`/`branchId` si se usan en otro lado del componente, pero deben añadirse los campos nuevos que sí viajan al backend).

**Criterio de aceptación:** Invitar un usuario nuevo desde "Equipo" → "Añadir Usuario" con un rol y sucursal seleccionados debe completar exitosamente (toast de éxito), no lanzar el error de campos obligatorios.

---

### A2. [ ] Tipos de contacto de proveedor usan acciones que no existen

**Backend (correcto, no tocar):** `c:\Desarrollos\supabase\supabase\functions\tenant-actions\index.ts:4233-4295` — las acciones genéricas `get_contact_types` (payload: `{ applies_to: 'supplier' | 'client' }`), `create_contact_type` (payload: `{ name, is_for_supplier, is_for_client }`), `update_contact_type` (payload: `{ id, ...updates }`), `delete_contact_type` (payload: `{ id }`) — todas sobre la tabla `contact_types` con columnas booleanas `is_for_supplier`/`is_for_client`.

**Frontend roto:** `c:\Desarrollos\Glamtica.app\src\hooks\useSupplierContactTypes.ts` (archivo completo, 56 líneas) y el mismo archivo en `TattooSuite.app`. Llama a `get_supplier_contact_types`, `create_supplier_contact_type`, `update_supplier_contact_type`, `delete_supplier_contact_type` — ninguna existe en el backend.

**Fix:** Reescribir `useSupplierContactTypes.ts` para usar las acciones genéricas:
```ts
export const useGetSupplierContactTypes = () => {
  return useQuery<SupplierContactType[], Error>({
    queryKey: ['supplier_contact_types'],
    queryFn: () => callTenantAction('get_contact_types', { applies_to: 'supplier' }),
  });
};

export const useCreateSupplierContactType = () => {
  const queryClient = useQueryClient();
  return useMutation<SupplierContactType, Error, { name: string }>({
    mutationFn: (newType) => callTenantAction('create_contact_type', { name: newType.name, is_for_supplier: true }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['supplier_contact_types'] }),
  });
};

export const useUpdateSupplierContactType = () => {
  const queryClient = useQueryClient();
  return useMutation<SupplierContactType, Error, Partial<SupplierContactType> & { id: string }>({
    mutationFn: (updates) => callTenantAction('update_contact_type', updates),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['supplier_contact_types'] }),
  });
};

export const useDeleteSupplierContactType = () => {
  const queryClient = useQueryClient();
  return useMutation<{ success: boolean }, Error, string>({
    mutationFn: (id) => callTenantAction('delete_contact_type', { id }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['supplier_contact_types'] }),
  });
};
```
Mantener el resto del archivo (imports, `SupplierContactType` interface, `callTenantAction`) igual.

**Criterio de aceptación:** La pantalla "Tipos de contacto de proveedor" (Configuración) debe listar, crear, editar y eliminar tipos sin error.

---

### A3. [ ] Widget "gastos pagados del mes" llama a una acción inexistente

**Backend (correcto, no tocar):** `c:\Desarrollos\supabase\supabase\functions\tenant-actions\index.ts:1512-1560` — la acción `get_monthly_expense_summary` (payload: `{ branchId }`) ya devuelve exactamente `{ paid: number, pending: number, overdue: number }` para el mes actual — es el mismo dato que consume la card "Gastos del Mes" del dashboard (Pagados/Pendientes/Vencidos).

**Frontend roto:** `c:\Desarrollos\Glamtica.app\src\hooks\useMonthlyPaidExpenses.ts:43-53` y el mismo archivo en `TattooSuite.app`. Llama a `get_current_month_paid_expenses` (no existe) y espera un `number` plano.

**Fix:** En la línea 45, cambiar:
```ts
action: 'get_current_month_paid_expenses',
```
por:
```ts
action: 'get_monthly_expense_summary',
```
Y en la línea 53, cambiar:
```ts
return data;
```
por:
```ts
return data.paid;
```

**Criterio de aceptación:** El widget de gastos pagados del mes (dashboard) debe mostrar un número real (o 0) en vez de quedar en error/loading infinito.

---

### A4. [ ] Detalle de equipo por ID llama a una acción inexistente (fix rápido, workaround client-side)

**Backend:** `c:\Desarrollos\supabase\supabase\functions\tenant-actions\index.ts:5215-5226` — `get_equipment` solo acepta `{ searchTerm, showInactive, typeId, brandId }`, **no** filtra por un ID puntual. No existe `get_equipment_by_id`.

**Frontend roto:** `c:\Desarrollos\Glamtica.app\src\hooks\useEquipment.ts:139` (hook `useEquipmentById`) y el mismo archivo en `TattooSuite.app`.

**Fix (workaround inmediato, sin tocar backend):** Cambiar la queryFn de `useEquipmentById` para invocar `get_equipment` sin filtros (o con `showInactive: true` para no perder equipos inactivos) y luego hacer `.find(e => e.id === equipmentId)` sobre el array resultante antes de retornar.

**Nota:** esto trae toda la lista de equipos solo para mostrar uno — aceptable si la lista de equipos de un tenant es chica (típico en salones/estudios), pero no es la solución ideal a largo plazo. Si el equipo de backend quiere la solución correcta más adelante, se debería agregar un parámetro `p_id` opcional al RPC `get_equipment` y su case correspondiente — no lo hagas ahora salvo que se pida explícitamente, este workaround ya destraba la funcionalidad.

**Criterio de aceptación:** La vista de detalle/edición de un equipo específico carga sus datos sin error.

---

## SECCIÓN B — Fixes de backend (agregar acciones faltantes siguiendo un patrón existente)

### B1. [ ] Gestión de imágenes de servicio — faltan 4 de 5 acciones (alta confianza, patrón claro)

**Archivo:** `c:\Desarrollos\supabase\supabase\functions\tenant-actions\index.ts`

**Contexto:** El bloque de imágenes (líneas ~5626-5811) implementa el mismo set de 5 acciones para `product`, `combo`, `treatment` y `project` (`get_X_images`, `associate_X_image`, `delete_X_image`, `set_primary_X_image`, y una única `update_product_images_order` compartida). Para `service` **solo existe `get_service_images` (línea 5788)**, que ya funciona y ya llama a un RPC `get_service_images` — es decir, el RPC de base de datos para servicios ya existe, solo falta cablear el resto de los cases en la Edge Function.

**Frontend que ya espera estas acciones (no tocar, ya están bien escritas):**
- `c:\Desarrollos\Glamtica.app\src\hooks\useServiceImages.ts:37,59,94`
- `c:\Desarrollos\Glamtica.app\src\components\service\ManageServiceImagesDialog.tsx:128,140,151`
- Mismos archivos en `TattooSuite.app`.

**Fix:** Agregar estos 3 cases nuevos al switch, ubicándolos junto a `get_service_images` (después de la línea 5795), mirando **exactamente** el patrón de `product`/`treatment` (cambiar `product`→`service`, `productId`→`serviceId`, `treatment_id`→`service_id`):
```ts
case 'associate_service_image': {
  const { serviceId, google_drive_file_id } = payload;
  if (!serviceId || !google_drive_file_id) {
    throw new Error('serviceId and google_drive_file_id are required.');
  }
  responseData = await callRpc(supabaseAdmin, 'associate_service_image', {
    p_tenant_id: tenantId,
    p_platform_id: platformId,
    p_service_id: serviceId,
    p_google_drive_file_id: google_drive_file_id,
  });
  break;
}

case 'delete_service_image': {
  const { imageId } = payload;
  if (!imageId) throw new Error('Image ID is required.');
  responseData = await callRpc(supabaseAdmin, 'delete_service_image', { p_tenant_id: tenantId, p_platform_id: platformId, p_image_id: imageId });
  break;
}

case 'set_primary_service_image': {
  const { serviceId, imageId } = payload;
  if (!serviceId || !imageId) throw new Error('Service ID and Image ID are required.');
  responseData = await callRpc(supabaseAdmin, 'set_primary_service_image', {
    p_tenant_id: tenantId,
    p_platform_id: platformId,
    p_service_id: serviceId,
    p_image_id: imageId,
  });
  break;
}

case 'update_service_images_order': {
  const { images_data } = payload;
  if (!images_data) throw new Error('images_data is required for update_service_images_order.');
  const { error } = await supabaseAdmin.rpc('update_service_images_order', {
    p_tenant_id: tenantId,
    p_platform_id: platformId,
    p_images_data: images_data,
  });
  if (error) throw error;
  responseData = { success: true };
  break;
}
```
**IMPORTANTE — verificar antes de dar por terminada la tarea:** este fix asume que los RPCs de Postgres `associate_service_image`, `delete_service_image`, `set_primary_service_image` y `update_service_images_order` **ya existen en la base de datos** (por analogía con `get_service_images`, que si existe y funciona). Si al probar alguno de los 4 nuevos cases la Edge Function devuelve un error tipo "function ... does not exist" desde Postgres, el RPC específico falta y hay que crearlo (mirar la definición SQL de `associate_product_image`/`delete_product_image`/etc. como plantilla, replicando para la tabla de imágenes de servicio). No asumas el nombre de la tabla sin verificarla primero.

**Criterio de aceptación:** Desde `ManageServiceImagesDialog`, subir una imagen a un servicio, marcarla como principal, reordenar y eliminarla deben funcionar sin error.

---

### B2. [ ] Falta lectura de configuración de notificaciones

**Archivo:** `c:\Desarrollos\supabase\supabase\functions\tenant-actions\index.ts`

**Contexto:** `update_notification_settings` (línea 3572-3594) ya existe y escribe en la tabla `tenant_template_settings` (columnas: `tenant_id, platform_id, template_type, is_active`). No existe ningún case de **lectura** — `get_notification_settings`.

**Frontend que ya espera esta acción:** `c:\Desarrollos\Glamtica.app\src\hooks\useNotificationSettings.ts:14` (usado por `Settings\NotificationSettingsTab.tsx`) y mismo archivo en `TattooSuite.app`. Revisar ese hook primero para confirmar la forma exacta de dato que espera recibir (`Array<{ template_type, is_active }>` es lo más probable, dado el formato de `update_notification_settings`).

**Fix:** Agregar, cerca de `update_notification_settings`, un case nuevo:
```ts
case 'get_notification_settings': {
  if (!tenantId) throw new Error('Tenant ID is required.');
  const { data, error } = await supabaseAdmin
    .from('tenant_template_settings')
    .select('template_type, is_active')
    .eq('tenant_id', tenantId)
    .eq('platform_id', platformId);
  if (error) throw error;
  responseData = data;
  break;
}
```

**Criterio de aceptación:** La pestaña "Notificaciones" en Configuración debe cargar el estado actual de cada switch (activo/inactivo) en vez de quedar siempre vacía/loading.

---

### B3. [ ] Eliminar producto o servicio maestro no existe en el backend

**Archivo:** `c:\Desarrollos\supabase\supabase\functions\tenant-actions\index.ts`

**Contexto:** `update_master_product` (línea ~4496) y `update_master_service` (línea 4464) existen; no existe `delete_master_product` ni `delete_master_service`.

**Frontend que ya espera estas acciones:** `c:\Desarrollos\Glamtica.app\src\hooks\useProducts.ts:197` y `c:\Desarrollos\Glamtica.app\src\hooks\useServices.ts:283` (y sus equivalentes en `TattooSuite.app`).

**Fix:** Agregar los dos cases nuevos, con el mismo scoping por `tenant_id`/`platform_id` que usa `update_master_product`/`update_master_service`:
```ts
case 'delete_master_product': {
  const { id } = payload;
  if (!id) throw new Error('Product ID is required.');
  const { error } = await supabaseAdmin
    .from('products')
    .delete()
    .eq('id', id)
    .eq('tenant_id', tenantId)
    .eq('platform_id', platformId);
  if (error) throw error;
  responseData = { success: true };
  break;
}

case 'delete_master_service': {
  const { id } = payload;
  if (!id) throw new Error('Service ID is required.');
  const { error } = await supabaseAdmin
    .from('services')
    .delete()
    .eq('id', id)
    .eq('tenant_id', tenantId)
    .eq('platform_id', platformId);
  if (error) throw error;
  responseData = { success: true };
  break;
}
```
**IMPORTANTE — verificar antes de dar por terminada la tarea:** confirmar el nombre real de la tabla de productos (`products` es la suposición razonable dado `update_master_product`, pero verificar leyendo el bloque completo de `update_master_product`, que quedó cortado en la auditoría). Si hay otras tablas con foreign key hacia `products`/`services` (ítems de combos, historial de atenciones, etc.), un `DELETE` directo puede fallar por constraint — en ese caso, evaluar cambiar a un soft-delete (`UPDATE ... SET is_active = false`) en vez de `DELETE`, igual que probablemente ya hace el toggle "Activo" que se vio en la UI de Productos/Servicios.

**Criterio de aceptación:** Eliminar un producto o servicio maestro sin atenciones/combos asociados debe funcionar. Si tiene referencias, debe fallar con un mensaje de error claro (o aplicarse como soft-delete), no con un error genérico de constraint de base de datos.

---

### B4. [ ] Actualización masiva de precios de combo por sucursal — decidir enfoque

**Archivo backend:** `c:\Desarrollos\supabase\supabase\functions\tenant-actions\index.ts:7680` (acción existente `update_combo_branch_prices`, actualiza **un** combo a la vez: payload `{ combo_id, branch_id, price_overrides }`).

**Frontend roto:** `c:\Desarrollos\Glamtica.app\src\hooks\useServices.ts:266` (y equivalente en `TattooSuite.app`) llama a `bulk_update_branch_combo_prices`, que no existe.

**Fix recomendado (más simple, sin tocar backend):** En el hook, reemplazar la llamada única por un `Promise.all` que invoque `update_combo_branch_prices` una vez por cada combo a actualizar, reusando la acción existente.

**Alternativa (si el volumen de combos por sucursal es grande y el loop es lento):** implementar un case `bulk_update_branch_combo_prices` real en el backend que reciba un array y haga un solo `upsert` masivo. Priorizar la opción simple primero; solo pasar a la alternativa si en la práctica el loop resulta notablemente lento.

**Criterio de aceptación:** El diálogo de edición masiva de precios de combo por sucursal (`BulkEditBranchPricesDialog.tsx` o similar) debe guardar todos los cambios sin error.

---

### B5. [ ] Confirmación de pago de atención vía Wompi — acción no existe (requiere investigación previa)

**Frontend:** `c:\Desarrollos\Glamtica.app\src\pages\PaymentSuccess.tsx:18-23` y equivalente en `TattooSuite.app` — invoca `update-attention-payment-status` al volver de Wompi tras pagar una cita/atención.

**Backend:** no existe ningún case `update-attention-payment-status` en `tenant-actions/index.ts`.

**Esta tarea NO es un mirror trivial** — antes de escribir código, investigar:
1. Qué payload envía exactamente `PaymentSuccess.tsx` (leer el archivo completo, no solo las líneas 18-23) — probablemente incluye un ID de transacción de Wompi y/o el ID de la atención.
2. Buscar en `tenant-actions/index.ts` la acción `process_attention_payment` (mencionada como ya funcional en la auditoría) — puede que ese sea el mecanismo real de confirmación de pago y que `PaymentSuccess.tsx` esté usando una acción vieja/obsoleta en vez de la vigente. Si es así, el fix puede ser tan simple como cambiar el `action` en el frontend.
3. Si `process_attention_payment` no cubre el caso (ej. no está pensado para pagos async vía redirect de pasarela), recién ahí evaluar crear `update-attention-payment-status` desde cero, y en ese caso consultar con el usuario el flujo esperado antes de implementar (qué estados de pago existen, qué debe pasar con la atención si el pago falla, etc.).

**Criterio de aceptación:** Después de pagar una atención vía Wompi y volver a la app, la atención debe quedar marcada como pagada.

---

### B6. [ ] Encuesta de satisfacción — no se puede cargar por token

**Frontend:** `c:\Desarrollos\Glamtica.app\src\pages\SurveyPage.tsx:89-92` y equivalente en `TattooSuite.app` — invoca `GET_SURVEY_DETAILS_BY_TOKEN` contra `public-actions`.

**Backend:** `c:\Desarrollos\supabase\supabase\functions\public-actions\index.ts` no tiene ese case. Sí existe `SUBMIT_SURVEY` (el envío de respuestas) — usar esa acción como referencia para saber en qué tabla(s) vive la encuesta y sus preguntas.

**Fix:** Leer la implementación de `SUBMIT_SURVEY` para identificar la(s) tabla(s) de encuestas/preguntas/token, y agregar un case `GET_SURVEY_DETAILS_BY_TOKEN` que, dado un `token`, devuelva los datos que `SurveyPage.tsx` necesita para renderizar el formulario (leer el componente para saber exactamente qué campos consume del resultado antes de decidir el `SELECT`).

**Criterio de aceptación:** Abrir el link de una encuesta enviada a un cliente debe mostrar las preguntas, no un error de carga.

---

## SECCIÓN C — Requiere decisión del usuario antes de tocar código

### C1. [ ] `WompiCheckout.tsx` — checkout de monto libre no envía `userId`/`planId`

**Backend:** `c:\Desarrollos\supabase\Core\supabase\functions\core-actions\index.ts:1776-1780` exige `tenantId, redirectUrl, userId, planId` para `generate_wompi_checkout`.

**Frontend:** `WompiCheckout.tsx` (ambas apps) solo envía `{ tenantId, amountInCents, currency, redirectUrl }` — sin `userId` ni `planId`. Comparar con `SubscriptionPlans.tsx:37`, que sí envía los 4 campos correctamente para suscribirse a un plan.

**Por qué no ejecutar un fix automático:** no está claro si `WompiCheckout.tsx` es una pantalla vigente para "pagar un monto libre" (en cuyo caso el backend necesitaría soportar un modo sin `planId`) o si es una pantalla vieja que debería directamente redirigir a `SubscriptionPlans.tsx`. Cualquiera de las dos implica una decisión de producto, no solo de código.

**Pedir al usuario:** ¿`WompiCheckout.tsx` sigue usándose desde algún flujo activo (ej. pagar una atención puntual) o es una pantalla legada que puede eliminarse/redirigir?

---

### C2. [ ] Bug de notificación silenciosa al crear una atención (bajo impacto)

**Archivo:** `c:\Desarrollos\supabase\supabase\functions\tenant-actions\index.ts` — dentro del case `create_full_attention` (línea 6179 en adelante).

**Problema:** El frontend envía los campos con prefijo `p_` (`p_client_id`, `p_services`, etc., que es lo correcto para el RPC). Pero la lógica de notificación al profesional asignado, más abajo en el mismo case, lee `payload.services`, `payload.client_id`, `payload.attention_datetime` **sin el prefijo `p_`** — esas claves nunca llegan, así que la condición siempre es falsy y la notificación nunca se dispara. No hay error visible, solo una notificación que nunca llega al profesional.

**Por qué no ejecutar un fix automático:** es un cambio en lógica de notificaciones (no en el contrato de payload en sí), y antes de tocarlo vale confirmar con el usuario si esta notificación es una funcionalidad activa que se espera que funcione, o si quedó obsoleta.

**Pedir al usuario:** ¿la notificación al profesional al crear una atención debería estar funcionando hoy? Si sí, el fix es leer `payload.p_services`, `payload.p_client_id`, `payload.p_attention_datetime` en vez de las versiones sin prefijo.

---

### C3. [ ] Nota de seguridad — posible bypass de aislamiento de tenant (requiere revisión de backend, no autofix)

**Archivo:** `c:\Desarrollos\supabase\supabase\functions\tenant-actions\index.ts` — cases `get-dashboard-stats` (línea 1562) y `get-today-attentions` (línea 1575).

**Problema:** A diferencia de `get-top-services`/`get-pending-commissions` (que sobreescriben `tenantId`/`branchId` con los valores del JWT del usuario autenticado), estos dos cases reenvían `p_tenant_id`/`p_branch_id`/`p_user_id` tal como llegan en el payload del cliente al RPC, ejecutado con `supabaseAdmin` (que bypassa RLS). Hoy funciona porque el frontend siempre envía los valores correctos, pero en teoría alguien podría manipular el payload del request y pedir estadísticas de otro tenant.

**No es un mismatch de payload — es una decisión de seguridad del backend.** No debe ejecutarse un fix automático sin que el equipo de backend confirme el criterio correcto (probablemente: siempre tomar `tenantId`/`branchId` del JWT decodificado, ignorando lo que venga en el payload del cliente, igual que ya hacen `get-top-services`/`get-pending-commissions`).

**Pedir al usuario:** confirmar si se prioriza este fix de seguridad y con qué urgencia, antes de tocarlo.

---

## SECCIÓN D — Menores / cleanup (opcional, bajo impacto)

- [ ] `c:\Desarrollos\Glamtica.app\src\hooks\useTreatments.ts:160-181` exporta `useProducts`/`useServices` que llaman a acciones inexistentes (`list_products`/`list_services`), pero no están importados por ningún componente activo — código muerto que colisiona de nombre con los hooks reales `useProducts.ts`/`useServices.ts`. Verificar con grep de imports antes de borrar, y borrar si efectivamente no se usa.
- [ ] Varios hooks envían campos que el backend ignora silenciosamente (`useEquipmentAssignments.ts:27,49,92` envía `tenantId` de más; `useProductTransfers.ts:11` envía `tenantId` de más; `usePaymentMethods.tsx:12` envía `tenantId` de más; `useCreatePaymentMethod.ts:12` envía `tenant_id` de más; `useDocumentTypes.ts:33` envía `is_active` que el backend descarta). Inofensivo, limpieza opcional.
- [ ] `useRegionalSettingsData.ts:14` arma el body con `JSON.stringify({...})` en vez del objeto plano `{ action, payload }` que usa el resto de la app — funciona igual mas es inconsistente. Unificar al patrón estándar.
- [ ] En `c:\Desarrollos\supabase\supabase\functions\tenant-actions\index.ts` hay 3 grupos de cases duplicados donde el primero siempre gana (JS `switch` nunca llega al segundo): `get_tenant_storage_usage` (líneas ~555 y ~3175), `update_sales_settings` (líneas ~2819 y ~3596), y el bloque de imágenes de tratamiento (~5708-5746 vía RPC vs ~8207-8273 con implementación distinta). No afecta funcionalidad hoy, pero es deuda técnica confusa para quien edite el archivo — eliminar la versión muerta (la segunda de cada par) después de confirmar cuál es la que realmente corre.

---

## Validación final

- [ ] Todas las tareas de Sección A y B completadas (o explícitamente descartadas con motivo anotado).
- [ ] Sección C discutida con el usuario antes de tocar código.
- [ ] Recorrer manualmente los flujos afectados: invitar usuario, tipos de contacto de proveedor, dashboard (widget de gastos), detalle de equipo, imágenes de servicio, notificaciones (configuración), eliminar producto/servicio maestro, precios masivos de combo.
