-- Migración en CORE: Crear publicación para replicación lógica de platforms

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'core_shared_platforms') THEN
        CREATE PUBLICATION core_shared_platforms FOR TABLE platforms;
    END IF;
END $$;
