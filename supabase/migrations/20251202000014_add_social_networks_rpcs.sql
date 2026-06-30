-- RPCs for tenant_social_networks

CREATE OR REPLACE FUNCTION public.list_tenant_social_networks(p_tenant_id uuid)
RETURNS SETOF public.tenant_social_networks
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY
    SELECT *
    FROM public.tenant_social_networks
    WHERE tenant_id = p_tenant_id
    ORDER BY network;
END;
$$;

CREATE OR REPLACE FUNCTION public.add_tenant_social_network(
    p_tenant_id uuid,
    p_network public.social_network,
    p_url text
)
RETURNS public.tenant_social_networks
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    new_record public.tenant_social_networks;
BEGIN
    INSERT INTO public.tenant_social_networks (tenant_id, network, url)
    VALUES (p_tenant_id, p_network, p_url)
    RETURNING * INTO new_record;
    RETURN new_record;
END;
$$;

CREATE OR REPLACE FUNCTION public.update_tenant_social_network(
    p_id uuid,
    p_tenant_id uuid,
    p_network public.social_network,
    p_url text
)
RETURNS public.tenant_social_networks
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    updated_record public.tenant_social_networks;
BEGIN
    UPDATE public.tenant_social_networks
    SET
        network = p_network,
        url = p_url,
        updated_at = now()
    WHERE id = p_id AND tenant_id = p_tenant_id
    RETURNING * INTO updated_record;
    RETURN updated_record;
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_tenant_social_network(
    p_id uuid,
    p_tenant_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    DELETE FROM public.tenant_social_networks
    WHERE id = p_id AND tenant_id = p_tenant_id;
END;
$$;


-- RPCs for branch_social_networks

CREATE OR REPLACE FUNCTION public.list_branch_social_networks(p_branch_id uuid)
RETURNS SETOF public.branch_social_networks
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY
    SELECT *
    FROM public.branch_social_networks
    WHERE branch_id = p_branch_id
    ORDER BY network;
END;
$$;

CREATE OR REPLACE FUNCTION public.add_branch_social_network(
    p_branch_id uuid,
    p_network public.social_network,
    p_url text
)
RETURNS public.branch_social_networks
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    new_record public.branch_social_networks;
BEGIN
    INSERT INTO public.branch_social_networks (branch_id, network, url)
    VALUES (p_branch_id, p_network, p_url)
    RETURNING * INTO new_record;
    RETURN new_record;
END;
$$;

CREATE OR REPLACE FUNCTION public.update_branch_social_network(
    p_id uuid,
    p_branch_id uuid,
    p_network public.social_network,
    p_url text
)
RETURNS public.branch_social_networks
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    updated_record public.branch_social_networks;
BEGIN
    UPDATE public.branch_social_networks
    SET
        network = p_network,
        url = p_url,
        updated_at = now()
    WHERE id = p_id AND branch_id = p_branch_id
    RETURNING * INTO updated_record;
    RETURN updated_record;
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_branch_social_network(
    p_id uuid,
    p_branch_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    DELETE FROM public.branch_social_networks
    WHERE id = p_id AND branch_id = p_branch_id;
END;
$$;
