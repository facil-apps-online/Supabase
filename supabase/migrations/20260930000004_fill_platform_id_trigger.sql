-- Tras el refactor multi-plataforma, ~115 tablas exigen platform_id NOT NULL sin default, pero decenas de funciones
-- SQL (start_service, end_service, create_equipment_type, process_recurring_expenses, ...) insertan sin enviarlo.
-- Todas esas tablas tienen tenant_id y tenants.platform_id, asi que se completa automaticamente en BEFORE INSERT.
-- (Los INSERT que tampoco envian tenant_id siguen fallando y hay que corregirlos en su funcion.)

CREATE OR REPLACE FUNCTION public.fill_platform_id_from_tenant()
RETURNS trigger LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.platform_id IS NULL AND NEW.tenant_id IS NOT NULL THEN
    SELECT t.platform_id INTO NEW.platform_id FROM public.tenants t WHERE t.id = NEW.tenant_id LIMIT 1;
  END IF;
  RETURN NEW;
END;
$function$;

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT c.relname
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
    JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'platform_id' AND a.attnotnull AND NOT a.attisdropped
    JOIN pg_attribute t ON t.attrelid = c.oid AND t.attname = 'tenant_id' AND NOT t.attisdropped
    LEFT JOIN pg_attrdef d ON d.adrelid = c.oid AND d.adnum = a.attnum
    WHERE c.relkind = 'r' AND d.adbin IS NULL AND c.relname <> 'tenants'
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS aa_fill_platform_id ON public.%I', r.relname);
    EXECUTE format('CREATE TRIGGER aa_fill_platform_id BEFORE INSERT ON public.%I FOR EACH ROW EXECUTE FUNCTION public.fill_platform_id_from_tenant()', r.relname);
  END LOOP;
END
$$;
