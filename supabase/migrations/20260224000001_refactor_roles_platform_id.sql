-- Migración: Refactorización de la tabla roles para incluir platform_id obligatorio y PK compuesta
-- Se corrige error de columna inexistente y se optimiza la duplicación.
-- Timestamp: 20260224000001

BEGIN;

-- 1. Eliminar restricciones de FK y unicidad temporales
ALTER TABLE IF EXISTS public.user_assignments DROP CONSTRAINT IF EXISTS user_assignments_role_id_fkey;
ALTER TABLE IF EXISTS public.roles DROP CONSTRAINT IF EXISTS roles_name_key;

-- 2. Crear tabla temporal para mapear IDs antiguos a nuevos
CREATE TEMP TABLE role_mapping (
    old_id uuid,
    new_id uuid,
    platform_id uuid
);

-- 3. Insertar nuevos roles para Tattoo Suite y capturar mapeo
-- Tattoo Suite: 6a6f73c8-2224-4eaf-b40d-da41bd75958a
DO $$
DECLARE
    r RECORD;
    new_uuid uuid;
    tattoo_suite_id uuid := '6a6f73c8-2224-4eaf-b40d-da41bd75958a';
BEGIN
    FOR r IN SELECT * FROM public.roles WHERE platform_id IS NULL LOOP
        new_uuid := gen_random_uuid();
        INSERT INTO public.roles (id, name, display_name, description, platform_id, tenant_id)
        VALUES (new_uuid, r.name, r.display_name, r.description, tattoo_suite_id, r.tenant_id);
        
        INSERT INTO role_mapping (old_id, new_id, platform_id)
        VALUES (r.id, new_uuid, tattoo_suite_id);
    END LOOP;
END $$;

-- 4. Insertar nuevos roles para Glamtica y capturar mapeo
-- Glamtica: ca9090c3-f6a3-46c3-af1d-6362e2942e5f
DO $$
DECLARE
    r RECORD;
    new_uuid uuid;
    glamtica_id uuid := 'ca9090c3-f6a3-46c3-af1d-6362e2942e5f';
BEGIN
    -- Procesamos los mismos roles originales (que siguen teniendo platform_id NULL)
    FOR r IN SELECT * FROM public.roles WHERE platform_id IS NULL LOOP
        new_uuid := gen_random_uuid();
        INSERT INTO public.roles (id, name, display_name, description, platform_id, tenant_id)
        VALUES (new_uuid, r.name, r.display_name, r.description, glamtica_id, r.tenant_id);
        
        INSERT INTO role_mapping (old_id, new_id, platform_id)
        VALUES (r.id, new_uuid, glamtica_id);
    END LOOP;
END $$;

-- 5. Actualizar asignaciones en user_assignments basándose en la plataforma
-- Mapea el ID antiguo al nuevo ID correspondiente a la plataforma del usuario
UPDATE public.user_assignments ua
SET role_id = rm.new_id
FROM role_mapping rm
WHERE ua.role_id = rm.old_id AND ua.platform_id = rm.platform_id;

-- 6. Eliminar roles originales (los que tienen platform_id NULL)
DELETE FROM public.roles WHERE platform_id IS NULL;

-- 7. Ajustar estructura de la tabla roles
-- Hacer platform_id obligatorio
ALTER TABLE public.roles ALTER COLUMN platform_id SET NOT NULL;

-- Cambiar la PK
ALTER TABLE public.roles DROP CONSTRAINT IF EXISTS roles_pkey CASCADE;
ALTER TABLE public.roles ADD PRIMARY KEY (id, platform_id);

-- 8. Crear nueva restricción de unicidad compuesta (Nombre + Plataforma)
ALTER TABLE public.roles ADD CONSTRAINT roles_name_platform_key UNIQUE (name, platform_id);

-- 9. Restaurar restricción de FK en user_assignments
ALTER TABLE public.user_assignments
ADD CONSTRAINT user_assignments_role_id_fkey 
FOREIGN KEY (role_id, platform_id) 
REFERENCES public.roles(id, platform_id) 
ON UPDATE CASCADE;

COMMIT;
