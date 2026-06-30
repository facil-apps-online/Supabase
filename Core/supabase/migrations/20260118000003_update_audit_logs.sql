-- Migración: Actualización de auditoría para agrupación y nombres de usuario
-- Proyecto: Core

-- 1. Modificar tabla audit_logs
ALTER TABLE public.audit_logs
ADD COLUMN IF NOT EXISTS module text,
ADD COLUMN IF NOT EXISTS root_entity_id uuid,
ADD COLUMN IF NOT EXISTS root_entity_type text,
ADD COLUMN IF NOT EXISTS user_name text;

-- Indices para búsquedas eficientes en el Chatter
CREATE INDEX IF NOT EXISTS idx_audit_logs_root_entity ON public.audit_logs(tenant_id, root_entity_type, root_entity_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_module ON public.audit_logs(tenant_id, module);

-- 2. Actualizar RPC log_audit_action_core
-- Nota: Incluye todos los parámetros anteriores + los nuevos
CREATE OR REPLACE FUNCTION public.log_audit_action_core(
    p_tenant_id uuid,
    p_user_id uuid,
    p_user_name text,
    p_branch_id uuid,
    p_action text,
    p_module text,
    p_entity_type text,
    p_entity_id uuid,
    p_root_entity_type text,
    p_root_entity_id uuid,
    p_old_value jsonb,
    p_new_value jsonb,
    p_metadata jsonb,
    p_ip_address inet,
    p_user_agent text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_platform_id uuid;
BEGIN
    SELECT platform_id INTO v_platform_id FROM public.tenants WHERE id = p_tenant_id;

    IF v_platform_id IS NOT NULL THEN
        INSERT INTO public.audit_logs (
            tenant_id,
            platform_id,
            user_id,
            user_name,
            branch_id,
            action,
            module,
            entity_type,
            entity_id,
            root_entity_type,
            root_entity_id,
            old_value,
            new_value,
            metadata,
            ip_address,
            user_agent
        ) VALUES (
            p_tenant_id,
            v_platform_id,
            p_user_id,
            p_user_name,
            p_branch_id,
            p_action,
            p_module,
            p_entity_type,
            p_entity_id,
            p_root_entity_type,
            p_root_entity_id,
            p_old_value,
            p_new_value,
            p_metadata,
            p_ip_address,
            p_user_agent
        );
    END IF;
END;
$function$;
