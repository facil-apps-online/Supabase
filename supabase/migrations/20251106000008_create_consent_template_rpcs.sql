-- Helper function to get the current tenant_id from the JWT claims
CREATE OR REPLACE FUNCTION get_current_tenant_id()
RETURNS uuid AS $$
DECLARE
    tenant_id uuid;
BEGIN
    SELECT NULLIF(current_setting('request.jwt.claims', true)::jsonb -> 'app_metadata' -> 'assignments' -> 0 ->> 'tenant_id', '')::uuid INTO tenant_id;
    RETURN tenant_id;
END;
$$ LANGUAGE plpgsql STABLE;

-- RPC to list all consent templates for the current tenant
CREATE OR REPLACE FUNCTION list_consent_templates()
RETURNS SETOF public.informed_consent_templates
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY
    SELECT *
    FROM public.informed_consent_templates
    WHERE tenant_id = get_current_tenant_id()
    ORDER BY name;
END;
$$;

-- RPC to get a single consent template by ID
CREATE OR REPLACE FUNCTION get_consent_template(p_id uuid)
RETURNS SETOF public.informed_consent_templates
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY
    SELECT *
    FROM public.informed_consent_templates
    WHERE id = p_id AND tenant_id = get_current_tenant_id();
END;
$$;

-- RPC to create a new consent template
CREATE OR REPLACE FUNCTION create_consent_template(
    p_name text,
    p_content text,
    p_fields jsonb
)
RETURNS public.informed_consent_templates
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    new_template public.informed_consent_templates;
BEGIN
    INSERT INTO public.informed_consent_templates (name, content, fields, tenant_id)
    VALUES (p_name, p_content, p_fields, get_current_tenant_id())
    RETURNING * INTO new_template;

    RETURN new_template;
END;
$$;

-- RPC to update an existing consent template
CREATE OR REPLACE FUNCTION update_consent_template(
    p_id uuid,
    p_name text,
    p_content text,
    p_fields jsonb,
    p_is_active boolean
)
RETURNS public.informed_consent_templates
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    updated_template public.informed_consent_templates;
BEGIN
    UPDATE public.informed_consent_templates
    SET
        name = p_name,
        content = p_content,
        fields = p_fields,
        is_active = p_is_active,
        updated_at = now()
    WHERE id = p_id AND tenant_id = get_current_tenant_id()
    RETURNING * INTO updated_template;

    RETURN updated_template;
END;
$$;
