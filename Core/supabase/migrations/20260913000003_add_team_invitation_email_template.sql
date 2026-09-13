-- Migration: Plantilla de correo para invitar al equipo comercial al portal Superadmin de
-- Facil Apps Online. A diferencia de las demás plantillas de client_email_queue, esta es
-- platform_id NULL a propósito — es una invitación interna al portal de administración, no
-- referencia ningún producto/plataforma en particular.

INSERT INTO public.email_templates (
    tenant_id, template_type, name, subject, body_html, language_id, platform_id,
    propagate_to_new_tenants, is_customizable, is_disableable
)
SELECT NULL, 'team_invitation', 'Invitación al equipo Facil Apps Online',
    'Te invitaron al portal de administración de Facil Apps Online',
    '<p>Hola {{user_name}},</p><p>Te invitaron a unirte al equipo comercial del portal de administración de <strong>Facil Apps Online</strong>. Haz clic en el siguiente enlace para crear tu contraseña y empezar a usarlo (válido por 1 hora):</p><p><a href="{{reset_link}}">Crear mi contraseña</a></p><p>Si no esperabas esta invitación, puedes ignorar este correo.</p>',
    'f1154a99-712d-49fe-9c36-86e8360fbaa9', NULL, false, true, false
WHERE NOT EXISTS (
    SELECT 1 FROM public.email_templates
    WHERE template_type = 'team_invitation' AND platform_id IS NULL AND tenant_id IS NULL
);
