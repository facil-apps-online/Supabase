-- Function to toggle the is_active status of a consent template
CREATE OR REPLACE FUNCTION toggle_consent_template_status(
    p_tenant_id uuid,
    p_id uuid
)
RETURNS public.informed_consent_templates
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    updated_template public.informed_consent_templates;
BEGIN
    UPDATE public.informed_consent_templates
    SET is_active = NOT is_active
    WHERE id = p_id AND tenant_id = p_tenant_id
    RETURNING * INTO updated_template;

    RETURN updated_template;
END;
$$;
