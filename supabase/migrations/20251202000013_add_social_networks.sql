CREATE TYPE public.social_network AS ENUM (
    'Instagram',
    'Facebook',
    'X',
    'TikTok',
    'WhatsApp',
    'LinkedIn',
    'YouTube',
    'Website'
);

CREATE TABLE public.tenant_social_networks (
    id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
    network public.social_network NOT NULL,
    url text NOT NULL CHECK (url ~* '^https?://'),
    created_at timestamptz DEFAULT now() NOT NULL,
    updated_at timestamptz,
    CONSTRAINT tenant_social_networks_tenant_id_network_key UNIQUE (tenant_id, network)
);

CREATE TABLE public.branch_social_networks (
    id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
    branch_id uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
    network public.social_network NOT NULL,
    url text NOT NULL CHECK (url ~* '^https?://'),
    created_at timestamptz DEFAULT now() NOT NULL,
    updated_at timestamptz,
    CONSTRAINT branch_social_networks_branch_id_network_key UNIQUE (branch_id, network)
);

-- RLS Policies
ALTER TABLE public.tenant_social_networks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.branch_social_networks ENABLE ROW LEVEL SECURITY;

-- Comments for clarity
COMMENT ON TABLE public.tenant_social_networks IS 'Stores social media links for tenants.';
COMMENT ON TABLE public.branch_social_networks IS 'Stores social media links for individual branches.';
