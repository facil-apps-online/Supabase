-- Migration: Agrega el logo de Facil Apps Online a la plantilla team_invitation. Es una
-- invitación genérica (platform_id NULL, no hay tenant ni plataforma cuyo logo_url usar), así
-- que se referencia directo el logo horizontal ya publicado en el sitio de marketing —
-- consistente con cómo Facil Factura hardcodea su propio logo por defecto en
-- PasswordResetService.cs cuando no hay uno de tenant.

UPDATE public.email_templates
SET body_html = '<div style="text-align:center;margin-bottom:24px"><img src="https://facil-apps.online/logo-full.png" alt="Facil Apps Online" style="max-height:64px;max-width:280px" /></div><p>Hola {{user_name}},</p><p>Te invitaron a unirte al equipo comercial del portal de administración de <strong>Facil Apps Online</strong>. Haz clic en el siguiente enlace para crear tu contraseña y empezar a usarlo (válido por 1 hora):</p><p><a href="{{reset_link}}">Crear mi contraseña</a></p><p>Si no esperabas esta invitación, puedes ignorar este correo.</p>'
WHERE template_type = 'team_invitation' AND platform_id IS NULL AND tenant_id IS NULL;
