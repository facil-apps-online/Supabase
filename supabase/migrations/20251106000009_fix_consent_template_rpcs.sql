-- Fix for create_consent_template to allow optional content and fields
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

-- Make update_consent_template more robust by handling optional parameters
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
