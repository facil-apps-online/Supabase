-- Crear tabla para preferencias de notificación por usuario
CREATE TABLE public.notification_preferences (
    id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID NOT NULL,
    tenant_id UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
    receive_summary BOOLEAN DEFAULT false, -- true = consolidadas, false = individuales
    summary_frequency TEXT DEFAULT 'daily', -- 'daily', 'weekly'
    email_enabled BOOLEAN DEFAULT true,
    in_app_enabled BOOLEAN DEFAULT true,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    UNIQUE(user_id, tenant_id)
);

-- Crear tabla para preferencias de notificación por rol (hereda si el usuario no tiene preferencia)
CREATE TABLE public.role_notification_preferences (
    id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    role_id UUID NOT NULL REFERENCES public.roles(id) ON DELETE CASCADE,
    tenant_id UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
    receive_summary BOOLEAN DEFAULT false,
    summary_frequency TEXT DEFAULT 'daily',
    email_enabled BOOLEAN DEFAULT true,
    in_app_enabled BOOLEAN DEFAULT true,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    UNIQUE(role_id, tenant_id)
);

-- Tabla para tracking de notificaciones pendientes de enviar en resumen
CREATE TABLE public.pending_summary_notifications (
    id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID NOT NULL,
    tenant_id UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
    notification_type TEXT NOT NULL,
    title TEXT NOT NULL,
    message TEXT NOT NULL,
    link TEXT,
    related_entity_id UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    processed BOOLEAN DEFAULT false,
    processed_at TIMESTAMP WITH TIME ZONE
);

-- Habilitar RLS
ALTER TABLE public.notification_preferences ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.role_notification_preferences ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pending_summary_notifications ENABLE ROW LEVEL SECURITY;

-- Políticas para notification_preferences
CREATE POLICY "Users can manage own notification preferences"
ON public.notification_preferences
FOR ALL
USING (user_id = auth.uid() OR is_super_admin(auth.uid()));

CREATE POLICY "Tenant admins can view tenant notification preferences"
ON public.notification_preferences
FOR SELECT
USING (tenant_id = get_user_tenant_id(auth.uid()));

-- Políticas para role_notification_preferences
CREATE POLICY "Super admins can manage all role notification preferences"
ON public.role_notification_preferences
FOR ALL
USING (is_super_admin(auth.uid()));

CREATE POLICY "Tenant admins can manage role notification preferences"
ON public.role_notification_preferences
FOR ALL
USING (tenant_id = get_user_tenant_id(auth.uid()));

-- Políticas para pending_summary_notifications
CREATE POLICY "System can manage pending notifications"
ON public.pending_summary_notifications
FOR ALL
USING (user_id = auth.uid() OR is_super_admin(auth.uid()));

-- Función para obtener preferencias de notificación efectivas del usuario
CREATE OR REPLACE FUNCTION public.get_user_notification_preferences(_user_id UUID)
RETURNS TABLE (
    receive_summary BOOLEAN,
    summary_frequency TEXT,
    email_enabled BOOLEAN,
    in_app_enabled BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    _tenant_id UUID;
BEGIN
    -- Obtener tenant del usuario
    SELECT tenant_id INTO _tenant_id FROM profiles WHERE user_id = _user_id LIMIT 1;
    
    -- Primero buscar preferencias del usuario
    RETURN QUERY
    SELECT np.receive_summary, np.summary_frequency, np.email_enabled, np.in_app_enabled
    FROM notification_preferences np
    WHERE np.user_id = _user_id AND np.tenant_id = _tenant_id
    LIMIT 1;
    
    IF NOT FOUND THEN
        -- Si no hay preferencias de usuario, buscar por rol
        RETURN QUERY
        SELECT rnp.receive_summary, rnp.summary_frequency, rnp.email_enabled, rnp.in_app_enabled
        FROM role_notification_preferences rnp
        INNER JOIN user_roles ur ON ur.role_id = rnp.role_id
        WHERE ur.user_id = _user_id AND rnp.tenant_id = _tenant_id
        LIMIT 1;
    END IF;
    
    IF NOT FOUND THEN
        -- Valores por defecto
        RETURN QUERY SELECT false, 'daily'::TEXT, true, true;
    END IF;
END;
$$;

-- Trigger para updated_at
CREATE TRIGGER update_notification_preferences_updated_at
    BEFORE UPDATE ON public.notification_preferences
    FOR EACH ROW
    EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_role_notification_preferences_updated_at
    BEFORE UPDATE ON public.role_notification_preferences
    FOR EACH ROW
    EXECUTE FUNCTION public.update_updated_at_column();