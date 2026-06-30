DO $$
DECLARE
    v_category_id UUID;
    v_http_method_id UUID;
    v_body_format_id UUID;
    v_auth_method_id UUID;
    v_country_colombia_id UUID;
BEGIN
    -- Ensure lookup entries exist and get their IDs
    INSERT INTO public.integration_categories (name, slug, description)
    VALUES ('Facturación Electrónica', 'electronic_invoicing', 'Proveedores de servicios de facturación electrónica.')
    ON CONFLICT (slug) DO UPDATE SET name = EXCLUDED.name, description = EXCLUDED.description
    RETURNING id INTO v_category_id;

    INSERT INTO public.integration_http_methods (method, description)
    VALUES ('POST', 'Método HTTP POST para enviar datos.')
    ON CONFLICT (method) DO UPDATE SET description = EXCLUDED.description
    RETURNING id INTO v_http_method_id;

    INSERT INTO public.integration_body_formats (format, description)
    VALUES ('JSON', 'Formato de cuerpo de solicitud JSON.')
    ON CONFLICT (format) DO UPDATE SET description = EXCLUDED.description
    RETURNING id INTO v_body_format_id;

    INSERT INTO public.integration_auth_methods (method, description, config_schema)
    VALUES (
        'Dataico Custom Headers',
        'Autenticación usando Dataico_account_id y Auth-token en los encabezados.',
        '{"Dataico_account_id": {"type": "string", "description": "ID de la cuenta Dataico"}, "Auth-token": {"type": "string", "description": "Token de autenticación Dataico"}}'::jsonb
    )
    ON CONFLICT (method) DO UPDATE SET description = EXCLUDED.description, config_schema = EXCLUDED.config_schema
    RETURNING id INTO v_auth_method_id;

    -- Get country_id for Colombia (assuming it exists)
    SELECT id INTO v_country_colombia_id FROM public.countries WHERE iso_code = 'CO';

    -- Update integration_providers entry for Dataico
    UPDATE public.integration_providers
    SET
        name = 'Dataico Facturación Electrónica',
        logo_url = 'https://www.dataico.com/wp-content/uploads/2020/12/logoblanco.svg',
        country_id = v_country_colombia_id,
        category_id = v_category_id,
        status = 'active',
        endpoints = '{"test": "https://api.dataico.com/direct/dataico_api/v2/invoices", "production": "https://api.dataico.com/direct/dataico_api/v2/invoices"}'::jsonb,
        config_schema = '[{"id": "dataico_account_id_field", "name": "Dataico_account_id", "type": "text", "label": "Dataico Account Id", "helpText": "ID de la cuenta Dataico", "required": true, "sandboxValue": ""}, {"id": "auth_token_field", "name": "Auth-token", "type": "text", "label": "Dataico Auth Token", "helpText": "Token de autenticación Dataico", "required": true, "sandboxValue": ""}]'::jsonb,
        api_schema = '{
            "actions": {
                "send_dian": {"type": "boolean", "glamticaMap": "{{invoice.actions.send_dian}}"},
                "send_email": {"type": "boolean", "glamticaMap": "{{invoice.actions.send_email}}"}
            },
            "invoice": {
                "env": {"type": "string", "glamticaMap": "{{invoice.env}}"},
                "number": {"type": "string", "glamticaMap": "{{invoice.number}}"},
                "dataico_account_id": {"type": "string", "glamticaMap": "{{tenant.dataico_account_id}}"},
                "issue_date": {"type": "string", "glamticaMap": "{{invoice.issue_date}}"},
                "payment_date": {"type": "string", "glamticaMap": "{{invoice.payment_date}}"},
                "invoice_type_code": {"type": "string", "glamticaMap": "{{invoice.invoice_type_code}}"},
                "payment_means": {"type": "string", "glamticaMap": "{{invoice.payment_means}}"},
                "payment_means_type": {"type": "string", "glamticaMap": "{{invoice.payment_means_type}}"},
                "order_reference": {"type": "string", "glamticaMap": "{{invoice.order_reference}}"},
                "numbering": {
                    "resolution_number": {"type": "string", "glamticaMap": "{{invoice.numbering.resolution_number}}"},
                    "prefix": {"type": "string", "glamticaMap": "{{invoice.numbering.prefix}}"},
                    "flexible": {"type": "boolean", "glamticaMap": "{{invoice.numbering.flexible}}"}
                },
                "customer": {
                    "party_identification_type": {"type": "string", "glamticaMap": "{{invoice.customer.party_identification_type}}"},
                    "party_identification": {"type": "string", "glamticaMap": "{{invoice.customer.party_identification}}"},
                    "party_type": {"type": "string", "glamticaMap": "{{invoice.customer.party_type}}"},
                    "tax_level_code": {"type": "string", "glamticaMap": "{{invoice.customer.tax_level_code}}"},
                    "regimen": {"type": "string", "glamticaMap": "{{invoice.customer.regimen}}"},
                    "company_name": {"type": "string", "glamticaMap": "{{invoice.customer.company_name}}"},
                    "first_name": {"type": "string", "glamticaMap": "{{invoice.customer.first_name}}"},
                    "family_name": {"type": "string", "glamticaMap": "{{invoice.customer.family_name}}"},
                    "department": {"type": "string", "glamticaMap": "{{invoice.customer.department}}"},
                    "city": {"type": "string", "glamticaMap": "{{invoice.customer.city}}"},
                    "address_line": {"type": "string", "glamticaMap": "{{invoice.customer.address_line}}"},
                    "country_code": {"type": "string", "glamticaMap": "{{invoice.customer.country_code}}"},
                    "email": {"type": "string", "glamticaMap": "{{invoice.customer.email}}"},
                    "phone": {"type": "string", "glamticaMap": "{{invoice.customer.phone}}"}
                },
                "items": [
                    {
                        "sku": {"type": "string", "glamticaMap": "{{item.sku}}"},
                        "quantity": {"type": "number", "glamticaMap": "{{item.quantity}}"},
                        "description": {"type": "string", "glamticaMap": "{{item.description}}"},
                        "measuring_unit": {"type": "string", "glamticaMap": "{{item.measuring_unit}}"},
                        "price": {"type": "number", "glamticaMap": "{{item.price}}"}
                    }
                ],
                "notes": [
                    {"type": "string", "glamticaMap": "{{invoice.notes}}"}
                ]
            }
        }'::jsonb,
        http_method_id = v_http_method_id,
        body_format_id = v_body_format_id,
        auth_method_id = v_auth_method_id,
        http_headers = '[{"name": "Content-Type", "value": "application/json"}, {"name": "Accept", "value": "application/json"}, {"name": "Dataico_account_id", "value_from_config": "Dataico_account_id"}, {"name": "Auth-token", "value_from_config": "Auth-token"}]'::jsonb,
        authentication_config = NULL,
        body_template = NULL,
        response_mapping = NULL,
        updated_at = NOW()
    WHERE slug = 'dataico_fe_co';
END;
$$;