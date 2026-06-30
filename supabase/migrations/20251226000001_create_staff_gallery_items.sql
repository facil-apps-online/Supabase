CREATE TABLE public.staff_gallery_items (
    id BIGSERIAL PRIMARY KEY,
    tenant_id UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE, -- ID del profesional
    evidence_id UUID NOT NULL REFERENCES public.attention_service_evidences(id) ON DELETE CASCADE, -- ID de la evidencia
    display_order INT NOT NULL DEFAULT 0, -- Orden en la galería
    is_favorite BOOLEAN NOT NULL DEFAULT FALSE, -- Si es un trabajo favorito
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT staff_gallery_items_unique_entry UNIQUE (tenant_id, user_id, evidence_id)
);

-- Índices para optimizar las consultas
CREATE INDEX idx_staff_gallery_items_tenant_user ON public.staff_gallery_items (tenant_id, user_id);

-- Trigger para actualizar el campo updated_at (asumo que la función ya existe)
CREATE TRIGGER update_staff_gallery_items_updated_at
BEFORE UPDATE ON public.staff_gallery_items
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();
