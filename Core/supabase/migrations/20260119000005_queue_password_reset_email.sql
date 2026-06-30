-- Eliminar la versión anterior por si se ejecutó parcialmente
DROP FUNCTION IF EXISTS public.queue_password_reset_email(text, text, uuid, uuid);

CREATE OR REPLACE FUNCTION public.queue_password_reset_email(
    p_email text,
    p_token text,
    p_platform_id uuid,
    p_tenant_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_reset_link text;
    v_template_data jsonb;
    v_platform_domain text;
BEGIN
    -- 1. Obtener el dominio de la plataforma para construir el enlace
    SELECT domain INTO v_platform_domain FROM public.platforms WHERE id = p_platform_id;
    IF v_platform_domain IS NULL THEN
        -- Como fallback, podríamos usar una URL genérica, pero es mejor que falle para detectar el problema.
        RAISE EXCEPTION 'Platform domain not found for platform_id: %', p_platform_id;
    END IF;

    v_reset_link := 'https://' || v_platform_domain || '/update-password?token=' || p_token;

    -- 2. Preparar el payload para la plantilla
    v_template_data := jsonb_build_object(
        'reset_link', v_reset_link
        -- Aquí se podrían añadir más variables como 'user_name' si se pasara a la RPC
    );

    -- 3. Insertar en la cola de correos, incluyendo el platform_id
    INSERT INTO public.client_email_queue (
        tenant_id,
        platform_id, -- Columna crucial para la selección de plantilla
        recipient_email,
        template_type,
        template_data,
        status
    ) VALUES (
        p_tenant_id,
        p_platform_id,
        p_email,
        'password_reset', -- Tipo de plantilla estándar para esta acción
        v_template_data,
        'PENDING'
    );

    RETURN jsonb_build_object('success', true, 'message', 'Correo de reseteo de contraseña encolado correctamente.');

EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING '[queue_password_reset_email] - Error: %', SQLERRM;
        RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;