-- Habilita el envío de correo transaccional (reseteo de contraseña, invitaciones) para
-- plataformas cuyos destinatarios no siempre están asociados a un tenant — por ejemplo, el
-- personal Superadmin de una plataforma, que no pertenece a ningún tenant.
--
-- 1. client_email_queue.tenant_id y email_templates.tenant_id pasan a ser opcionales: un correo
--    o una plantilla con tenant_id NULL es de alcance "plataforma" (aplica a todos los tenants de
--    esa plataforma, incluido su personal interno sin tenant).
-- 2. Nuevo RPC queue_platform_email: a diferencia de queue_client_email (que exige un tenant_id
--    válido y deriva el platform_id desde la tabla tenants), este recibe el platform_id
--    explícito del llamador y el tenant_id es opcional — pensado para que cada plataforma cliente
--    (ej. Facil Factura) arme el mensaje completo (enlace, texto) de su lado y Core solo lo envíe.
-- 3. Se siembran las plantillas 'password_reset' e 'invitation' en Español (Colombia) para la
--    plataforma de Facil Factura, de alcance plataforma (tenant_id NULL).

ALTER TABLE public.client_email_queue ALTER COLUMN tenant_id DROP NOT NULL;
ALTER TABLE public.email_templates ALTER COLUMN tenant_id DROP NOT NULL;

DROP FUNCTION IF EXISTS public.queue_platform_email(uuid, text, text, jsonb, uuid, uuid);
CREATE OR REPLACE FUNCTION public.queue_platform_email(
    p_platform_id uuid,
    p_recipient_email text,
    p_template_type text,
    p_template_data jsonb,
    p_tenant_id uuid DEFAULT NULL,
    p_recipient_client_id uuid DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
BEGIN
    INSERT INTO public.client_email_queue (
        tenant_id, platform_id, recipient_client_id, recipient_email, template_type, template_data, status
    ) VALUES (
        p_tenant_id, p_platform_id, p_recipient_client_id, p_recipient_email, p_template_type, p_template_data, 'PENDING'
    );
END;
$function$;

-- logo_url y brand_name identifican al Tenant dueño de la cuenta (el revendedor cuya marca
-- reconoce el destinatario) — Facil Factura los resuelve de su lado antes de encolar (con su
-- propio logo como fallback si el Tenant no tiene uno propio, o si no hay Tenant — ej. reset de
-- Superadmin), así que aquí siempre llegan con un valor usable.
--
-- id se genera aleatoriamente en cada INSERT (no hay una columna natural para ON CONFLICT), así
-- que la idempotencia se protege con este guard en vez de ON CONFLICT.
INSERT INTO public.email_templates (tenant_id, template_type, name, subject, body_html, language_id, platform_id, propagate_to_new_tenants, is_customizable, is_disableable)
SELECT NULL, 'password_reset', 'Restablecer contraseña', 'Restablece tu contraseña en {{brand_name}}',
    '<div style="text-align:center;margin-bottom:24px"><img src="{{logo_url}}" alt="{{brand_name}}" style="max-height:64px;max-width:240px" /></div><p>Hola {{user_name}},</p><p>Recibimos una solicitud para restablecer tu contraseña en {{brand_name}}. Haz clic en el siguiente enlace para crear una nueva (válido por 1 hora):</p><p><a href="{{reset_link}}">Restablecer mi contraseña</a></p><p>Si tú no solicitaste esto, puedes ignorar este correo.</p>',
    'f1154a99-712d-49fe-9c36-86e8360fbaa9', 'acd97b41-2e4d-4742-9a80-5e6e9acb7958', false, true, false
WHERE NOT EXISTS (
    SELECT 1 FROM public.email_templates
    WHERE template_type = 'password_reset' AND platform_id = 'acd97b41-2e4d-4742-9a80-5e6e9acb7958' AND tenant_id IS NULL
);

INSERT INTO public.email_templates (tenant_id, template_type, name, subject, body_html, language_id, platform_id, propagate_to_new_tenants, is_customizable, is_disableable)
SELECT NULL, 'invitation', 'Invitación a tu portal', 'Te invitaron a tu portal de {{brand_name}}',
    '<div style="text-align:center;margin-bottom:24px"><img src="{{logo_url}}" alt="{{brand_name}}" style="max-height:64px;max-width:240px" /></div><p>Hola {{user_name}},</p><p>Te crearon un acceso al portal de {{brand_name}}. Haz clic en el siguiente enlace para crear tu contraseña y empezar a usarlo (válido por 1 hora):</p><p><a href="{{reset_link}}">Crear mi contraseña</a></p>',
    'f1154a99-712d-49fe-9c36-86e8360fbaa9', 'acd97b41-2e4d-4742-9a80-5e6e9acb7958', false, true, false
WHERE NOT EXISTS (
    SELECT 1 FROM public.email_templates
    WHERE template_type = 'invitation' AND platform_id = 'acd97b41-2e4d-4742-9a80-5e6e9acb7958' AND tenant_id IS NULL
);
