-- Drop upsert_tenant_integration RPC as it has been moved to Core
-- Timestamp: 20260119000001

DROP FUNCTION IF EXISTS public.upsert_tenant_integration(uuid, text, text, text, text, text);
