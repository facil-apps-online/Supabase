-- Drop ONLY the functions specific to the consent template module
DROP FUNCTION IF EXISTS public.create_consent_template(text, text, jsonb);
DROP FUNCTION IF EXISTS public.update_consent_template(uuid, text, text, jsonb, boolean);
DROP FUNCTION IF EXISTS public.list_consent_templates();
DROP FUNCTION IF EXISTS public.get_consent_template(uuid);

-- Use CREATE OR REPLACE for the shared helper function to avoid breaking dependencies
CREATE OR REPLACE FUNCTION get_current_tenant_id()
RETURNS uuid AS $$
DECLARE
    tenant_id uuid;
BEGIN
    SELECT NULLIF(current_setting('request.jwt.claims', true)::jsonb -> 'app_metadata' -> 'assignments' -> 0 ->> 'tenant_id', '')::uuid INTO tenant_id;
    RETURN tenant_id;
END;
$$ LANGUAGE plpgsql STABLE;

-- Recreate the RPC functions with the correct signatures

-- list_consent_templates
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

-- get_consent_template
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

-- create_consent_template (with defaults)
CREATE OR REPLACE FUNCTION create_consent_template(
    p_name text,
    p_content text DEFAULT NULL,
    p_fields jsonb DEFAULT NULL
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

-- update_consent_template (with defaults and COALESCE)
CREATE OR REPLACE FUNCTION update_consent_template(
    p_id uuid,
    p_name text DEFAULT NULL,
    p_content text DEFAULT NULL,
    p_fields jsonb DEFAULT NULL,
    p_is_active boolean DEFAULT NULL
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
        name = COALESCE(p_name, name),
        content = COALESCE(p_content, content),
        fields = COALESCE(p_fields, fields),
        is_active = COALESCE(p_is_active, is_active),
        updated_at = now()
    WHERE id = p_id AND tenant_id = get_current_tenant_id()
    RETURNING * INTO updated_template;

    RETURN updated_template;
END;
$$;
