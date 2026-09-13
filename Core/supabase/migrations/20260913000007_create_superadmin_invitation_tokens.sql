-- Migration: Token de invitación propio para el equipo Superadmin, independiente del
-- mecanismo nativo de invite/recovery de Supabase Auth (que exige tocar Site URL / Redirect
-- URLs a nivel de proyecto y activa una sesión con solo abrir el link). El link solo permite
-- asignar la contraseña — nunca inicia sesión por sí mismo.

CREATE TABLE public.superadmin_invitation_tokens (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL,
  token_hash  text NOT NULL UNIQUE,
  expires_at  timestamptz NOT NULL,
  used_at     timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_superadmin_invitation_tokens_user ON public.superadmin_invitation_tokens (user_id);

ALTER TABLE public.superadmin_invitation_tokens ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Allow ALL for super_admin" ON public.superadmin_invitation_tokens
  USING (is_super_admin()) WITH CHECK (is_super_admin());
