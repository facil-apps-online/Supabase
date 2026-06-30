-- Migration: Corregir el parámetro de la función `list_treatment_prototypes` para usar `p_tenant_id`.
-- Version: 20251208000012

-- 1. Eliminar la función antigua que usa `p_business_id`
DROP FUNCTION IF EXISTS list_treatment_prototypes(p_business_id UUID, p_type TEXT);

-- 2. Crear la función corregida que usa `p_tenant_id`
CREATE OR REPLACE FUNCTION list_treatment_prototypes(p_tenant_id UUID, p_type TEXT)
RETURNS JSONB
LANGUAGE sql
STABLE
AS $$
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id', p.id,
      'name', p.name,
      'description', p.description,
      'type', p.type,
      'upfront_price', p.upfront_price,
      'financed_price', p.financed_price,
      'session_count', (SELECT COUNT(*) FROM prototype_sessions s WHERE s.prototype_id = p.id)
    ) ORDER BY p.name
  ), '[]'::jsonb)
  FROM treatment_prototypes p
  WHERE p.tenant_id = p_tenant_id AND p.type = p_type;
$$;

COMMENT ON FUNCTION list_treatment_prototypes IS '[FIX] Usa tenant_id en lugar de business_id.';
