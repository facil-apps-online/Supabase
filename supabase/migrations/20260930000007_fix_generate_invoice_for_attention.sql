-- generate_invoice_for_attention fallaba: usaba v_service.price / v_product.price (las columnas son service_price / unit_price),
-- reiniciaba el subtotal en cada ítem, y los invoice_items no enviaban tenant_id/platform_id (NOT NULL).
CREATE OR REPLACE FUNCTION public.generate_invoice_for_attention(p_attention_id uuid, p_platform_id uuid DEFAULT NULL::uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_invoice_id UUID;
    v_attention RECORD;
    v_tenant_id UUID;
    v_platform_id UUID;
    v_client_id UUID;
    v_service RECORD;
    v_product RECORD;
    v_subtotal NUMERIC := 0;
    v_total_tax NUMERIC := 0;
    v_currency_id UUID;
BEGIN
    SELECT * INTO v_attention FROM public.attentions WHERE id = p_attention_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Attention % not found.', p_attention_id;
    END IF;
    v_tenant_id := v_attention.tenant_id;
    v_platform_id := COALESCE(p_platform_id, v_attention.platform_id);
    v_client_id := v_attention.client_id;

    SELECT id INTO v_invoice_id FROM public.invoices WHERE attention_id = p_attention_id AND tenant_id = v_tenant_id AND platform_id = v_platform_id;
    IF v_invoice_id IS NOT NULL THEN
        RETURN v_invoice_id;
    END IF;

    SELECT COALESCE(b.currency_id, t.default_currency_id) INTO v_currency_id
    FROM public.tenants t
    LEFT JOIN public.branches b ON b.id = v_attention.branch_id AND b.tenant_id = t.id AND b.platform_id = t.platform_id
    WHERE t.id = v_tenant_id AND t.platform_id = v_platform_id;
    IF v_currency_id IS NULL THEN
        RAISE EXCEPTION 'No se pudo determinar la moneda (sucursal/tenant sin currency_id) para el tenant %.', v_tenant_id;
    END IF;

    INSERT INTO public.invoices (
        tenant_id, platform_id, billed_to_client_id, attention_id, invoice_number, status,
        subtotal_amount, total_tax_amount, total_amount, issue_date, due_date, currency_id
    ) VALUES (
        v_tenant_id, v_platform_id, v_client_id, p_attention_id,
        'INV-' || to_char(CURRENT_DATE, 'YYYYMMDD') || '-' || (SELECT count(*) + 1 FROM public.invoices WHERE tenant_id = v_tenant_id AND platform_id = v_platform_id),
        'paid', 0, 0, v_attention.total_amount, CURRENT_DATE, CURRENT_DATE, v_currency_id
    ) RETURNING id INTO v_invoice_id;

    FOR v_service IN SELECT * FROM public.attention_services WHERE attention_id = p_attention_id AND tenant_id = v_tenant_id AND platform_id = v_platform_id LOOP
        INSERT INTO public.invoice_items (tenant_id, platform_id, invoice_id, service_id, item_type, description, quantity, unit_price, total_price)
        VALUES (v_tenant_id, v_platform_id, v_invoice_id, v_service.service_id, 'SERVICE',
                COALESCE((SELECT name FROM public.services WHERE id = v_service.service_id AND tenant_id = v_tenant_id AND platform_id = v_platform_id), 'Servicio'),
                1, v_service.service_price, v_service.service_price);
        v_subtotal := v_subtotal + COALESCE(v_service.service_price, 0);
    END LOOP;

    FOR v_product IN SELECT * FROM public.attention_products WHERE attention_id = p_attention_id AND tenant_id = v_tenant_id AND platform_id = v_platform_id LOOP
        INSERT INTO public.invoice_items (tenant_id, platform_id, invoice_id, product_id, item_type, description, quantity, unit_price, total_price)
        VALUES (v_tenant_id, v_platform_id, v_invoice_id, v_product.product_id, 'PRODUCT',
                COALESCE((SELECT name FROM public.products WHERE id = v_product.product_id AND tenant_id = v_tenant_id AND platform_id = v_platform_id), 'Producto'),
                v_product.quantity, v_product.unit_price, v_product.unit_price * v_product.quantity);
        v_subtotal := v_subtotal + (v_product.unit_price * v_product.quantity);
    END LOOP;

    UPDATE public.invoices
       SET subtotal_amount = v_subtotal, total_tax_amount = v_total_tax, total_amount = v_subtotal + v_total_tax
     WHERE id = v_invoice_id AND tenant_id = v_tenant_id AND platform_id = v_platform_id;

    RETURN v_invoice_id;
END;
$function$;
