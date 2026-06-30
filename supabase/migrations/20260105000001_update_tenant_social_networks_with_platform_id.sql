-- First, update the unique constraint to include platform_id
ALTER TABLE public.tenant_social_networks
DROP CONSTRAINT IF EXISTS tenant_social_networks_tenant_id_network_key;

ALTER TABLE public.tenant_social_networks
ADD CONSTRAINT tenant_social_networks_platform_tenant_network_key UNIQUE (platform_id, tenant_id, network);

-- Now, update the CRUD functions

-- 1. LIST
DROP FUNCTION IF EXISTS public.list_tenant_social_networks(uuid);
CREATE OR REPLACE FUNCTION public.list_tenant_social_networks(p_tenant_id uuid, p_platform_id uuid)
RETURNS SETOF public.tenant_social_networks AS $$
BEGIN
    RETURN QUERY
    SELECT *
    FROM public.tenant_social_networks
    WHERE tenant_id = p_tenant_id AND platform_id = p_platform_id
    ORDER BY network;
END;
$$ LANGUAGE plpgsql;

-- 2. ADD
DROP FUNCTION IF EXISTS public.add_tenant_social_network(uuid, public.social_network, text);
CREATE OR REPLACE FUNCTION public.add_tenant_social_network(
    p_tenant_id uuid,
    p_platform_id uuid,
    p_network public.social_network,
    p_url text
)
RETURNS public.tenant_social_networks AS $$
DECLARE
    new_record public.tenant_social_networks;
BEGIN
    INSERT INTO public.tenant_social_networks (tenant_id, platform_id, network, url)
    VALUES (p_tenant_id, p_platform_id, p_network, p_url)
    RETURNING * INTO new_record;
    RETURN new_record;
END;
$$ LANGUAGE plpgsql;

-- 3. UPDATE
DROP FUNCTION IF EXISTS public.update_tenant_social_network(uuid, uuid, public.social_network, text);
CREATE OR REPLACE FUNCTION public.update_tenant_social_network(
    p_id uuid,
    p_tenant_id uuid,
    p_platform_id uuid,
    p_network public.social_network,
    p_url text
)
RETURNS public.tenant_social_networks AS $$
DECLARE
    updated_record public.tenant_social_networks;
BEGIN
    UPDATE public.tenant_social_networks
    SET
        network = p_network,
        url = p_url,
        updated_at = now()
    WHERE id = p_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id
    RETURNING * INTO updated_record;
    RETURN updated_record;
END;
$$ LANGUAGE plpgsql;

-- 4. DELETE
DROP FUNCTION IF EXISTS public.delete_tenant_social_network(uuid, uuid);
CREATE OR REPLACE FUNCTION public.delete_tenant_social_network(
    p_id uuid,
    p_tenant_id uuid,
    p_platform_id uuid
)
RETURNS void AS $$
BEGIN
    DELETE FROM public.tenant_social_networks
    WHERE id = p_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;
END;
$$ LANGUAGE plpgsql;
