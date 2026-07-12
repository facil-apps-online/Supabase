-- Tabla para registrar los nodos físicos/bases de datos (Services, Nexu, Core, etc)
CREATE TABLE IF NOT EXISTS public.infrastructure_nodes (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    node_name text NOT NULL,
    description text NULL,
    project_url text NOT NULL,
    service_role_key text NOT NULL,
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    updated_at timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT infrastructure_nodes_pkey PRIMARY KEY (id),
    CONSTRAINT infrastructure_nodes_name_key UNIQUE (node_name)
) TABLESPACE pg_default;

-- Disparador para actualizar updated_at
CREATE TRIGGER trg_infrastructure_nodes_updated_at 
BEFORE UPDATE ON public.infrastructure_nodes 
FOR EACH ROW 
EXECUTE FUNCTION tg_set_updated_at();

-- Enlazar la tabla de platforms con el nodo de infraestructura
ALTER TABLE public.platforms 
ADD COLUMN IF NOT EXISTS infrastructure_node_id uuid NULL,
ADD CONSTRAINT platforms_infrastructure_node_id_fkey 
    FOREIGN KEY (infrastructure_node_id) 
    REFERENCES public.infrastructure_nodes (id) 
    ON DELETE SET NULL;

-- Indice para mejorar la velocidad al agrupar o filtrar plataformas por nodo
CREATE INDEX IF NOT EXISTS idx_platforms_infrastructure_node 
ON public.platforms USING btree (infrastructure_node_id) TABLESPACE pg_default;

-- Comentarios documentales
COMMENT ON TABLE public.infrastructure_nodes IS 'Registro de instancias de bases de datos Supabase donde viven las plataformas y tenants.';
COMMENT ON COLUMN public.infrastructure_nodes.service_role_key IS 'Llave maestra para la comunicación segura entre bases desde las Edge Functions de Core.';
