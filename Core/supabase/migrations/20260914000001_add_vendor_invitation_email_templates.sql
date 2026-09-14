-- Correo de invitación de vendedor→prospecto (template_type 'vendor_invitation'), con el
-- logo y el color de marca de cada plataforma destino horneados en el HTML — a diferencia
-- de 'invitation' (Facil Factura), acá cada plataforma tiene UN logo/color fijo, no uno por
-- tenant, así que no hace falta pasarlo como variable en cada envío.
-- Variables: {{prospect_name}}, {{vendor_name}}, {{platform_name}}, {{invite_url}}.

BEGIN;

INSERT INTO public.email_templates (tenant_id, template_type, name, subject, body_html, language_id, platform_id, propagate_to_new_tenants, is_customizable, is_disableable)
SELECT NULL, 'vendor_invitation', 'Invitación de vendedor a prospecto', '{{vendor_name}} te invitó a probar {{platform_name}}',
    '<div style="text-align:center;margin-bottom:24px"><img src="https://glamtica.app/favicon-256x256.png" alt="Glamtica" style="max-height:64px;max-width:220px" /></div>' ||
    '<p>Hola {{prospect_name}},</p>' ||
    '<p>{{vendor_name}} te invitó a conocer {{platform_name}}. Crea tu cuenta y comienza tu prueba gratuita:</p>' ||
    '<p style="text-align:center;margin:32px 0"><a href="{{invite_url}}" style="background-color:#7e22ce;color:#ffffff;padding:14px 28px;border-radius:8px;text-decoration:none;font-weight:bold;display:inline-block">Crear mi cuenta</a></p>' ||
    '<p style="font-size:13px;color:#6b7280">Si el botón no funciona, copia y pega este enlace en tu navegador:<br/><a href="{{invite_url}}">{{invite_url}}</a></p>',
    'f1154a99-712d-49fe-9c36-86e8360fbaa9', 'ca9090c3-f6a3-46c3-af1d-6362e2942e5f', false, true, false
WHERE NOT EXISTS (
    SELECT 1 FROM public.email_templates
    WHERE template_type = 'vendor_invitation' AND platform_id = 'ca9090c3-f6a3-46c3-af1d-6362e2942e5f' AND tenant_id IS NULL
);

INSERT INTO public.email_templates (tenant_id, template_type, name, subject, body_html, language_id, platform_id, propagate_to_new_tenants, is_customizable, is_disableable)
SELECT NULL, 'vendor_invitation', 'Invitación de vendedor a prospecto', '{{vendor_name}} te invitó a probar {{platform_name}}',
    '<div style="text-align:center;margin-bottom:24px"><img src="https://tattoosuite.app/ms-icon-310x310.png" alt="Tattoo Suite" style="max-height:64px;max-width:220px" /></div>' ||
    '<p>Hola {{prospect_name}},</p>' ||
    '<p>{{vendor_name}} te invitó a conocer {{platform_name}}. Crea tu cuenta y comienza tu prueba gratuita:</p>' ||
    '<p style="text-align:center;margin:32px 0"><a href="{{invite_url}}" style="background-color:#00CCFF;color:#0a0a0a;padding:14px 28px;border-radius:8px;text-decoration:none;font-weight:bold;display:inline-block">Crear mi cuenta</a></p>' ||
    '<p style="font-size:13px;color:#6b7280">Si el botón no funciona, copia y pega este enlace en tu navegador:<br/><a href="{{invite_url}}">{{invite_url}}</a></p>',
    'f1154a99-712d-49fe-9c36-86e8360fbaa9', '6a6f73c8-2224-4eaf-b40d-da41bd75958a', false, true, false
WHERE NOT EXISTS (
    SELECT 1 FROM public.email_templates
    WHERE template_type = 'vendor_invitation' AND platform_id = '6a6f73c8-2224-4eaf-b40d-da41bd75958a' AND tenant_id IS NULL
);

INSERT INTO public.email_templates (tenant_id, template_type, name, subject, body_html, language_id, platform_id, propagate_to_new_tenants, is_customizable, is_disableable)
SELECT NULL, 'vendor_invitation', 'Invitación de vendedor a prospecto', '{{vendor_name}} te invitó a probar {{platform_name}}',
    '<div style="text-align:center;margin-bottom:24px"><img src="https://nexuhr.pro/nexurh-icon-256.png" alt="Nexu HR" style="max-height:64px;max-width:220px" /></div>' ||
    '<p>Hola {{prospect_name}},</p>' ||
    '<p>{{vendor_name}} te invitó a conocer {{platform_name}}. Crea tu cuenta y comienza tu prueba gratuita:</p>' ||
    '<p style="text-align:center;margin:32px 0"><a href="{{invite_url}}" style="background-color:#2a9d90;color:#ffffff;padding:14px 28px;border-radius:8px;text-decoration:none;font-weight:bold;display:inline-block">Crear mi cuenta</a></p>' ||
    '<p style="font-size:13px;color:#6b7280">Si el botón no funciona, copia y pega este enlace en tu navegador:<br/><a href="{{invite_url}}">{{invite_url}}</a></p>',
    'f1154a99-712d-49fe-9c36-86e8360fbaa9', 'd9a6ffdc-d1cc-4080-83c7-a9249800a94e', false, true, false
WHERE NOT EXISTS (
    SELECT 1 FROM public.email_templates
    WHERE template_type = 'vendor_invitation' AND platform_id = 'd9a6ffdc-d1cc-4080-83c7-a9249800a94e' AND tenant_id IS NULL
);

COMMIT;
