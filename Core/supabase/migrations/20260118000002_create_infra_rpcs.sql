-- Migración: RPCs para infraestructura centralizada
-- Proyecto: Core

-- 1. RPC: queue_client_email
DROP FUNCTION IF EXISTS public.queue_client_email(uuid, uuid, text, text, jsonb);
CREATE OR REPLACE FUNCTION public.queue_client_email(
    p_tenant_id uuid,
    p_recipient_client_id uuid,
    p_recipient_email text,
    p_template_type text,
    p_template_data jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_platform_id uuid;
BEGIN
    SELECT platform_id INTO v_platform_id FROM public.tenants WHERE id = p_tenant_id;

    IF v_platform_id IS NULL THEN
        RAISE WARNING 'Tenant % not found in Core.', p_tenant_id;
        RETURN;
    END IF;

    INSERT INTO public.client_email_queue (
        tenant_id, platform_id, recipient_client_id, recipient_email, template_type, template_data, status
    ) VALUES (
        p_tenant_id, v_platform_id, p_recipient_client_id, p_recipient_email, p_template_type, p_template_data, 'PENDING'
    );
END;
$function$;

-- 2. RPC: queue_client_whatsapp
DROP FUNCTION IF EXISTS public.queue_client_whatsapp(uuid, uuid, text, text, jsonb);
CREATE OR REPLACE FUNCTION public.queue_client_whatsapp(
    p_tenant_id uuid,
    p_recipient_client_id uuid,
    p_recipient_phone_number text,
    p_template_name text,
    p_template_params jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_platform_id uuid;
BEGIN
    SELECT platform_id INTO v_platform_id FROM public.tenants WHERE id = p_tenant_id;

    IF v_platform_id IS NULL THEN
        RAISE WARNING 'Tenant % not found in Core.', p_tenant_id;
        RETURN;
    END IF;

    INSERT INTO public.client_whatsapp_queue (
        tenant_id, platform_id, recipient_client_id, recipient_phone_number, template_name, template_params, status
    ) VALUES (
        p_tenant_id, v_platform_id, p_recipient_client_id, p_recipient_phone_number, p_template_name, p_template_params, 'PENDING'
    );
END;
$function$;

-- 3. RPC: log_api_metric
DROP FUNCTION IF EXISTS public.log_api_metric(uuid, text, text, integer, integer);
CREATE OR REPLACE FUNCTION public.log_api_metric(
    p_tenant_id uuid,
    p_path text,
    p_method text,
    p_status_code integer,
    p_response_time_ms integer
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
        INSERT INTO public.api_request_metrics (
            tenant_id, platform_id, path, method, status_code, response_time_ms
        ) VALUES (
            p_tenant_id, v_platform_id, p_path, p_method, p_status_code, p_response_time_ms
        );
    END IF;
END;
$function$;
