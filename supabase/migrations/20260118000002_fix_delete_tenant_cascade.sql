-- Actualización de delete_tenant_cascade para eliminar referencias a tablas migradas a Core
-- Proyecto: Servicios

CREATE OR REPLACE FUNCTION public.delete_tenant_cascade(target_tenant_id uuid)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE LOG 'Iniciando borrado en cascada (v4) para el tenant: %', target_tenant_id;

    -- Nivel 1: Datos de eventos y logs (audit_logs y metrics ya no existen en este esquema)
    
    RAISE LOG 'Borrando appointment_evidence...';
    DELETE FROM appointment_evidence WHERE tenant_id = target_tenant_id;
    RAISE LOG 'Borrando appointment_extra_services...';
    DELETE FROM appointment_extra_services WHERE tenant_id = target_tenant_id;
    RAISE LOG 'Borrando appointment_products...';
    DELETE FROM appointment_products WHERE tenant_id = target_tenant_id;
    RAISE LOG 'Borrando appointment_sessions...';
    DELETE FROM appointment_sessions WHERE tenant_id = target_tenant_id;
    RAISE LOG 'Borrando attention_products...';
    DELETE FROM attention_products WHERE tenant_id = target_tenant_id;
    RAISE LOG 'Borrando attention_service_products...';
    DELETE FROM attention_service_products WHERE tenant_id = target_tenant_id;
    RAISE LOG 'Borrando attention_services...';
    DELETE FROM attention_services WHERE tenant_id = target_tenant_id;
    RAISE LOG 'Borrando extra_service_sessions...';
    DELETE FROM extra_service_sessions WHERE tenant_id = target_tenant_id;
    RAISE LOG 'Borrando service_evidence...';
    DELETE FROM service_evidence WHERE tenant_id = target_tenant_id;
    RAISE LOG 'Borrando service_sessions...';
    DELETE FROM service_sessions WHERE tenant_id = target_tenant_id;
    RAISE LOG 'Borrando product_stylist_commissions...';
    DELETE FROM product_stylist_commissions WHERE tenant_id = target_tenant_id;
    RAISE LOG 'Borrando service_stylist_commissions...';
    DELETE FROM service_stylist_commissions WHERE tenant_id = target_tenant_id;
    RAISE LOG 'Borrando purchase_items...';
    DELETE FROM purchase_items WHERE tenant_id = target_tenant_id;
    RAISE LOG 'Borrando stylist_time_off...';
    DELETE FROM stylist_time_off WHERE tenant_id = target_tenant_id;
    RAISE LOG 'Borrando user_permissions...';
    DELETE FROM user_permissions WHERE tenant_id = target_tenant_id;
    RAISE LOG 'Borrando menu_permissions...';
    DELETE FROM menu_permissions WHERE tenant_id = target_tenant_id;

    -- Nivel 2: Entidades transaccionales principales
    RAISE LOG 'Borrando appointments...';
    DELETE FROM appointments WHERE tenant_id = target_tenant_id;
    RAISE LOG 'Borrando attentions...';
    DELETE FROM attentions WHERE tenant_id = target_tenant_id;
    RAISE LOG 'Borrando purchases...';
    DELETE FROM purchases WHERE tenant_id = target_tenant_id;
    RAISE LOG 'Borrando stylist_schedules...';
    DELETE FROM stylist_schedules WHERE tenant_id = target_tenant_id;

    -- Nivel 3: Usuarios y sus datos asociados
    RAISE LOG 'Borrando users...';
    DELETE FROM users WHERE tenant_id = target_tenant_id;
    RAISE LOG 'Borrando stylists...';
    DELETE FROM stylists WHERE tenant_id = target_tenant_id;
    RAISE LOG 'Borrando clients...';
    DELETE FROM clients WHERE tenant_id = target_tenant_id;

    -- Nivel 4: Catálogos y datos de negocio base
    RAISE LOG 'Borrando supplier_products...';
    DELETE FROM supplier_products WHERE tenant_id = target_tenant_id;
    RAISE LOG 'Borrando suppliers...';
    DELETE FROM suppliers WHERE tenant_id = target_tenant_id;
    RAISE LOG 'Borrando products...';
    DELETE FROM products WHERE tenant_id = target_tenant_id;
    RAISE LOG 'Borrando services...';
    DELETE FROM services WHERE tenant_id = target_tenant_id;
    RAISE LOG 'Borrando service_categories...';
    DELETE FROM service_categories WHERE tenant_id = target_tenant_id;
    RAISE LOG 'Borrando brands...';
    DELETE FROM brands WHERE tenant_id = target_tenant_id;
    RAISE LOG 'Borrando schedule_templates...';
    DELETE FROM schedule_templates WHERE tenant_id = target_tenant_id;

    -- Nivel 5: Configuración del Tenant
    RAISE LOG 'Borrando branches...';
    DELETE FROM branches WHERE tenant_id = target_tenant_id;
    RAISE LOG 'Borrando translations...';
    DELETE FROM translations WHERE tenant_id = target_tenant_id;
    RAISE LOG 'Borrando tenant_subscriptions...';
    DELETE FROM tenant_subscriptions WHERE tenant_id = target_tenant_id;

    -- Nivel Final: El tenant mismo
    RAISE LOG 'Borrando el tenant principal...';
    DELETE FROM tenants WHERE id = target_tenant_id;

    RAISE LOG 'Borrado en cascada (v4) completado para el tenant: %', target_tenant_id;
END;
$function$;
