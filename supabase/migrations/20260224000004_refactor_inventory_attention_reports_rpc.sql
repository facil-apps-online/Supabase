-- Migración: Refactorización de funciones RPC de Inventario, Atención, Reportes y Comisiones
-- Se agrega el parámetro p_platform_id y se estandarizan los filtros por tenant_id y platform_id.
-- Timestamp: 20260224000004

BEGIN;

--------------------------------------------------------------------------------
-- 1. create_product_transfer
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.create_product_transfer(uuid, uuid, uuid, timestamp with time zone, text, jsonb);
CREATE OR REPLACE FUNCTION public.create_product_transfer(
    p_tenant_id uuid, 
    p_platform_id uuid,
    p_from_branch_id uuid, 
    p_to_branch_id uuid, 
    p_transfer_date timestamp with time zone, 
    p_notes text, 
    p_items jsonb
)
 RETURNS uuid
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_transfer_id UUID;
    item RECORD;
BEGIN
    INSERT INTO product_transfers (tenant_id, platform_id, origin_branch_id, destination_branch_id, transfer_date, status, notes)
    VALUES (p_tenant_id, p_platform_id, p_from_branch_id, p_to_branch_id, p_transfer_date, 'solicitado', p_notes)
    RETURNING id INTO v_transfer_id;

    FOR item IN SELECT * FROM jsonb_to_recordset(p_items) AS x(product_id UUID, quantity numeric)
    LOOP
        INSERT INTO product_transfer_items (transfer_id, tenant_id, platform_id, product_id, quantity)
        VALUES (v_transfer_id, p_tenant_id, p_platform_id, item.product_id, item.quantity);

        -- El stock se resta usualmente cuando cambia a 'en_transito' o similar, 
        -- pero mantenemos la lógica original de restar al crear si así estaba.
        -- Ajustado para usar PK compuesta en el UPDATE
        UPDATE branch_products
        SET stock_quantity = stock_quantity - item.quantity
        WHERE branch_id = p_from_branch_id AND product_id = item.product_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;
    END LOOP;

    RETURN v_transfer_id;
END;
$function$;

--------------------------------------------------------------------------------
-- 2. receive_purchase
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.receive_purchase(uuid, uuid, uuid, jsonb, text);
CREATE OR REPLACE FUNCTION public.receive_purchase(
    p_tenant_id uuid, 
    p_platform_id uuid,
    p_purchase_id uuid, 
    p_branch_id uuid, 
    p_received_items jsonb, 
    p_reception_notes text
)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
    item RECORD;
    total_expected numeric := 0;
    total_received numeric := 0;
    new_status TEXT;
BEGIN
    FOR item IN SELECT * FROM jsonb_to_recordset(p_received_items) AS x(purchase_item_id UUID, product_id UUID, quantity_expected numeric, quantity_received numeric)
    LOOP
        UPDATE public.branch_products
        SET stock_quantity = stock_quantity + item.quantity_received
        WHERE branch_id = p_branch_id AND product_id = item.product_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;

        INSERT INTO public.purchase_item_receptions (purchase_item_id, purchase_id, tenant_id, platform_id, quantity_expected, quantity_received)
        VALUES (item.purchase_item_id, p_purchase_id, p_tenant_id, p_platform_id, item.quantity_expected, item.quantity_received);

        total_expected := total_expected + item.quantity_expected;
        total_received := total_received + item.quantity_received;
    END LOOP;

    IF total_received < total_expected THEN
        new_status := 'recibido_con_incidencias';
    ELSE
        new_status := 'completada';
    END IF;

    UPDATE public.purchases
    SET status = new_status,
        reception_notes = p_reception_notes,
        updated_at = now()
    WHERE id = p_purchase_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;

END;
$function$;

--------------------------------------------------------------------------------
-- 3. update_product_transfer_status
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.update_product_transfer_status(uuid, uuid, text);
CREATE OR REPLACE FUNCTION public.update_product_transfer_status(p_tenant_id uuid, p_platform_id uuid, p_transfer_id uuid, p_status text)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_transfer record;
    v_tenant_settings JSONB;
    v_costing_method TEXT;
    item record;
    v_from_branch_product record;
    v_to_branch_product record;
    v_new_cost_price NUMERIC;
BEGIN
    SELECT * INTO v_transfer FROM product_transfers WHERE id = p_transfer_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;

    SELECT settings_data INTO v_tenant_settings FROM tenant_settings WHERE tenant_id = p_tenant_id AND platform_id = p_platform_id;
    v_costing_method := v_tenant_settings->>'costing_method';

    UPDATE product_transfers SET status = p_status, updated_at = now() WHERE id = p_transfer_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;

    IF p_status = 'completado' THEN
        FOR item IN SELECT * FROM product_transfer_items WHERE transfer_id = p_transfer_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id
        LOOP
            SELECT * INTO v_from_branch_product FROM branch_products WHERE branch_id = v_transfer.origin_branch_id AND product_id = item.product_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;
            SELECT * INTO v_to_branch_product FROM branch_products WHERE branch_id = v_transfer.destination_branch_id AND product_id = item.product_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;

            IF v_costing_method = 'ponderado' AND (COALESCE(v_to_branch_product.stock_quantity, 0) + item.quantity) > 0 THEN
                v_new_cost_price := ((COALESCE(v_to_branch_product.stock_quantity, 0) * COALESCE(v_to_branch_product.cost_price, 0)) + (item.quantity * v_from_branch_product.cost_price)) / (v_to_branch_product.stock_quantity + item.quantity);
            ELSE
                v_new_cost_price := v_from_branch_product.cost_price;
            END IF;

            IF v_to_branch_product.id IS NOT NULL THEN
                UPDATE branch_products
                SET stock_quantity = stock_quantity + item.quantity,
                    cost_price = v_new_cost_price
                WHERE branch_id = v_transfer.destination_branch_id AND product_id = item.product_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;
            ELSE
                INSERT INTO branch_products (branch_id, product_id, tenant_id, platform_id, stock_quantity, cost_price)
                VALUES (v_transfer.destination_branch_id, item.product_id, p_tenant_id, p_platform_id, item.quantity, v_new_cost_price);
            END IF;
        END LOOP;
    END IF;

    IF p_status = 'cancelado' THEN
        FOR item IN SELECT * FROM product_transfer_items WHERE transfer_id = p_transfer_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id
        LOOP
            UPDATE branch_products
            SET stock_quantity = stock_quantity + item.quantity
            WHERE branch_id = v_transfer.origin_branch_id AND product_id = item.product_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;
        END LOOP;
    END IF;

END;
$function$;

--------------------------------------------------------------------------------
-- 4. cancel_purchase
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.cancel_purchase(uuid);
CREATE OR REPLACE FUNCTION public.cancel_purchase(p_tenant_id uuid, p_platform_id uuid, p_purchase_id uuid)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
BEGIN
    UPDATE public.purchases
    SET status = 'cancelada',
        updated_at = now()
    WHERE id = p_purchase_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;
END;
$function$;

--------------------------------------------------------------------------------
-- 5. search_products
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.search_products(uuid, text, boolean, uuid, uuid);
CREATE OR REPLACE FUNCTION public.search_products(
    p_tenant_id uuid, 
    p_platform_id uuid,
    p_search_term text, 
    p_show_inactive boolean, 
    p_category_id uuid, 
    p_brand_id uuid
)
 RETURNS TABLE(id uuid, name text, description text, is_active boolean, created_at timestamp with time zone, updated_at timestamp with time zone, cost_price numeric, last_purchase_cost numeric, average_cost numeric, brand_id uuid, barcode text, sku text, tenant_id uuid, platform_id uuid, name_i18n jsonb, description_i18n jsonb, unit_of_measure_id uuid, package_content_quantity numeric, allow_decimal_sale boolean, product_images jsonb, product_categories jsonb)
 LANGUAGE plpgsql
AS $function$
DECLARE
    search_words TEXT[];
    word TEXT;
    query_conditions TEXT[] := ARRAY[]::TEXT[];
    final_query TEXT;
BEGIN
    IF p_search_term IS NOT NULL AND p_search_term <> '' THEN
        search_words := string_to_array(lower(p_search_term), ' ');
    ELSE
        search_words := ARRAY[]::TEXT[];
    END IF;

    FOREACH word IN ARRAY search_words
    LOOP
        IF word <> '' THEN
            query_conditions := array_append(
                query_conditions,
                format(
                    '(p.name ILIKE %1$L OR p.description ILIKE %1$L OR p.sku ILIKE %1$L OR p.barcode ILIKE %1$L)',
                    '%' || word || '%'
                )
            );
        END IF;
    END LOOP;

    final_query := '
        SELECT
            p.id,
            p.name,
            p.description,
            p.is_active,
            p.created_at,
            p.updated_at,
            p.cost_price,
            p.last_purchase_cost,
            p.average_cost,
            p.brand_id,
            p.barcode,
            p.sku,
            p.tenant_id,
            p.platform_id,
            p.name_i18n,
            p.description_i18n,
            p.unit_of_measure_id,
            p.package_content_quantity,
            p.allow_decimal_sale,
            COALESCE(pi.images, ''[]''::jsonb) AS product_images,
            COALESCE(pc.categories, ''[]''::jsonb) as product_categories
        FROM
            public.products p
        LEFT JOIN (
            SELECT
                product_id,
                jsonb_agg(jsonb_build_object(
                    ''id'', id,
                    ''image_url'', image_url,
                    ''sort_order'', sort_order,
                    ''is_primary'', is_primary
                ) ORDER BY is_primary DESC, sort_order ASC) AS images
            FROM
                public.product_images
            WHERE tenant_id = $1 AND platform_id = $2
            GROUP BY
                product_id
        ) pi ON p.id = pi.product_id
        LEFT JOIN (
            SELECT
                pca.product_id,
                jsonb_agg(jsonb_build_object(''id'', pc.id, ''name'', pc.name) ORDER BY pc.name) AS categories
            FROM
                public.product_category_assignments pca
            JOIN
                public.product_categories pc ON pca.category_id = pc.id AND pca.tenant_id = pc.tenant_id AND pca.platform_id = pc.platform_id
            WHERE pca.tenant_id = $1 AND pca.platform_id = $2
            GROUP BY
                pca.product_id
        ) pc ON p.id = pc.product_id
        WHERE
            p.tenant_id = $1 AND p.platform_id = $2';

    IF NOT p_show_inactive THEN
        final_query := final_query || '
            AND p.is_active = TRUE';
    END IF;

    IF p_category_id IS NOT NULL THEN
        final_query := final_query || format('
            AND p.id IN (SELECT product_id FROM public.product_category_assignments WHERE category_id = %L AND tenant_id = %L AND platform_id = %L)', p_category_id, p_tenant_id, p_platform_id);
    END IF;

    IF p_brand_id IS NOT NULL THEN
        final_query := final_query || format('
            AND p.brand_id = %L', p_brand_id);
    END IF;

    IF array_length(query_conditions, 1) > 0 THEN
        final_query := final_query || '
            AND (' || array_to_string(query_conditions, ' AND ') || ')';
    END IF;

    final_query := final_query || '
        ORDER BY p.name;';

    RETURN QUERY EXECUTE final_query USING p_tenant_id, p_platform_id;
END;
$function$;

--------------------------------------------------------------------------------
-- 6. get_general_report
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_general_report(uuid, date, date);
CREATE OR REPLACE FUNCTION public.get_general_report(p_tenant_id uuid, p_platform_id uuid, p_date_from date, p_date_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN (SELECT jsonb_build_object(
        'totalRevenue', (SELECT COALESCE(SUM(total_amount), 0) FROM public.attentions WHERE tenant_id = p_tenant_id AND platform_id = p_platform_id AND status IN ('Completada', 'Pagada') AND attention_datetime::date BETWEEN p_date_from AND p_date_to),
        'completedAttentions', (SELECT COUNT(*) FROM public.attentions WHERE tenant_id = p_tenant_id AND platform_id = p_platform_id AND status IN ('Completada', 'Pagada') AND attention_datetime::date BETWEEN p_date_from AND p_date_to),
        'averageTicket', (SELECT COALESCE(AVG(total_amount), 0) FROM public.attentions WHERE tenant_id = p_tenant_id AND platform_id = p_platform_id AND status IN ('Completada', 'Pagada') AND attention_datetime::date BETWEEN p_date_from AND p_date_to)
    ));
END;
$function$;

--------------------------------------------------------------------------------
-- 7. get_service_report
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_service_report(uuid, date, date);
CREATE OR REPLACE FUNCTION public.get_service_report(p_tenant_id uuid, p_platform_id uuid, p_date_from date, p_date_to date)
 RETURNS TABLE(name text, count bigint, revenue numeric)
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN QUERY SELECT s.name, COUNT(aserv.id), SUM(aserv.service_price)
    FROM public.attention_services aserv
    JOIN public.services s ON aserv.service_id = s.id AND aserv.tenant_id = s.tenant_id AND aserv.platform_id = s.platform_id
    JOIN public.attentions a ON aserv.attention_id = a.id AND aserv.tenant_id = a.tenant_id AND aserv.platform_id = a.platform_id
    WHERE a.tenant_id = p_tenant_id AND a.platform_id = p_platform_id AND a.attention_datetime::date BETWEEN p_date_from AND p_date_to
    GROUP BY s.name ORDER BY count DESC;
END;
$function$;

--------------------------------------------------------------------------------
-- 8. adjust_purchase_total
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.adjust_purchase_total(uuid);
CREATE OR REPLACE FUNCTION public.adjust_purchase_total(p_tenant_id uuid, p_platform_id uuid, p_purchase_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_branch_id UUID;
    new_total_amount NUMERIC;
BEGIN
    SELECT branch_id INTO v_branch_id
    FROM public.purchases
    WHERE id = p_purchase_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;

    SELECT COALESCE(SUM(pri.quantity_received * bp.cost_price), 0)
    INTO new_total_amount
    FROM public.purchase_item_receptions pri
    JOIN public.purchase_items pi ON pri.purchase_item_id = pi.id AND pri.tenant_id = pi.tenant_id AND pri.platform_id = pi.platform_id
    JOIN public.branch_products bp ON pi.product_id = bp.product_id AND bp.branch_id = v_branch_id AND bp.tenant_id = p_tenant_id AND bp.platform_id = p_platform_id
    WHERE pi.purchase_id = p_purchase_id AND pi.tenant_id = p_tenant_id AND pi.platform_id = p_platform_id;

    UPDATE public.purchases
    SET total_amount = new_total_amount
    WHERE id = p_purchase_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;

END;
$function$;

--------------------------------------------------------------------------------
-- 9. receive_product_transfer
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.receive_product_transfer(uuid, text, jsonb, uuid, uuid);
CREATE OR REPLACE FUNCTION public.receive_product_transfer(p_transfer_id uuid, p_reception_notes text, p_received_items jsonb, p_tenant_id uuid, p_platform_id uuid, p_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_transfer record;
    v_reception_id uuid;
    v_item jsonb;
    v_transfer_item record;
    v_branch_product record;
    v_origin_branch_product record;
    v_costing_method text;
    v_new_cost_price numeric;
    v_has_discrepancies boolean := false;
BEGIN
    SELECT settings_data->>'costing_method' INTO v_costing_method
    FROM public.tenant_settings
    WHERE tenant_id = p_tenant_id AND platform_id = p_platform_id;
    v_costing_method := COALESCE(v_costing_method, 'average');

    SELECT * INTO v_transfer
    FROM public.product_transfers
    WHERE id = p_transfer_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id AND status = 'en_transito';

    IF v_transfer IS NULL THEN
        RAISE EXCEPTION 'Transferencia no encontrada o no está en estado "en_transito".';
    END IF;

    -- Nota: La verificación de permisos de usuario a sucursal se hace usualmente en la Edge o RLS, 
    -- pero mantengo el flujo de inserción reforzado.

    INSERT INTO public.product_transfer_receptions (transfer_id, tenant_id, platform_id, notes, reception_date)
    VALUES (p_transfer_id, p_tenant_id, p_platform_id, p_reception_notes, now())
    RETURNING id INTO v_reception_id;

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_received_items)
    LOOP
        SELECT * INTO v_transfer_item FROM public.product_transfer_items WHERE id = (v_item->>'transfer_item_id')::uuid AND tenant_id = p_tenant_id AND platform_id = p_platform_id;

        INSERT INTO public.product_transfer_reception_items (reception_id, transfer_item_id, product_id, tenant_id, platform_id, quantity_expected, quantity_received)
        VALUES (v_reception_id, v_transfer_item.id, v_transfer_item.product_id, p_tenant_id, p_platform_id, v_transfer_item.quantity, (v_item->>'quantity_received')::numeric);

        IF v_transfer_item.quantity <> (v_item->>'quantity_received')::numeric THEN
            v_has_discrepancies := true;
        END IF;

        SELECT * INTO v_branch_product FROM public.branch_products WHERE branch_id = v_transfer.destination_branch_id AND product_id = v_transfer_item.product_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;
        SELECT cost_price INTO v_origin_branch_product FROM public.branch_products WHERE branch_id = v_transfer.origin_branch_id AND product_id = v_transfer_item.product_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;

        IF v_branch_product.id IS NULL THEN
            INSERT INTO public.branch_products (branch_id, product_id, tenant_id, platform_id, stock_quantity, cost_price, is_active)
            VALUES (v_transfer.destination_branch_id, v_transfer_item.product_id, p_tenant_id, p_platform_id, (v_item->>'quantity_received')::numeric, v_origin_branch_product.cost_price, true);
        ELSE
            IF v_costing_method = 'average' AND (v_branch_product.stock_quantity + (v_item->>'quantity_received')::numeric) > 0 THEN
                v_new_cost_price := ((v_branch_product.stock_quantity * v_branch_product.cost_price) + ((v_item->>'quantity_received')::numeric * v_origin_branch_product.cost_price)) / (v_branch_product.stock_quantity + (v_item->>'quantity_received')::numeric);
            ELSE
                v_new_cost_price := v_origin_branch_product.cost_price;
            END IF;

            UPDATE public.branch_products
            SET
                stock_quantity = stock_quantity + (v_item->>'quantity_received')::numeric,
                cost_price = v_new_cost_price,
                updated_at = now()
            WHERE id = v_branch_product.id;
        END IF;
    END LOOP;

    UPDATE public.product_transfers
    SET status = CASE WHEN v_has_discrepancies THEN 'recibido_con_incidencias' ELSE 'completado' END, updated_at = now()
    WHERE id = p_transfer_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;

    RETURN jsonb_build_object('reception_id', v_reception_id);
END;
$function$;

--------------------------------------------------------------------------------
-- 10. create_product_movement
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.create_product_movement(uuid, uuid, uuid, text, numeric, numeric, uuid, text);
CREATE OR REPLACE FUNCTION public.create_product_movement(p_tenant_id uuid, p_platform_id uuid, p_branch_id uuid, p_product_id uuid, p_movement_type text, p_quantity_change numeric, p_cost_of_change numeric, p_reference_id uuid DEFAULT NULL::uuid, p_reference_type text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
    branch_product_rec RECORD;
    new_stock numeric;
    new_avg_cost numeric;
BEGIN
    SELECT *
    INTO branch_product_rec
    FROM public.branch_products
    WHERE branch_id = p_branch_id AND product_id = p_product_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Producto % no encontrado en la sucursal %', p_product_id, p_branch_id;
    END IF;

    new_stock := branch_product_rec.stock_quantity + p_quantity_change;

    IF new_stock > 0 THEN
        new_avg_cost := ((branch_product_rec.stock_quantity * branch_product_rec.cost_price) + (p_quantity_change * p_cost_of_change)) / new_stock;
    ELSE
        new_avg_cost := 0;
    END IF;

    UPDATE public.branch_products
    SET
        stock_quantity = new_stock,
        cost_price = new_avg_cost
    WHERE id = branch_product_rec.id;

    INSERT INTO public.product_movements (
        tenant_id,
        platform_id,
        branch_id,
        product_id,
        movement_date,
        movement_type,
        quantity_change,
        cost_of_change,
        stock_after_movement,
        cost_after_movement,
        reference_id,
        reference_type
    ) VALUES (
        p_tenant_id,
        p_platform_id,
        p_branch_id,
        p_product_id,
        now(),
        p_movement_type,
        p_quantity_change,
        p_cost_of_change,
        new_stock,
        new_avg_cost,
        p_reference_id,
        p_reference_type
    );

END;
$function$;

--------------------------------------------------------------------------------
-- 11. create_full_attention
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.create_full_attention(uuid, timestamp with time zone, text, jsonb, jsonb, jsonb, jsonb, uuid, uuid, numeric);
CREATE OR REPLACE FUNCTION public.create_full_attention(p_client_id uuid, p_attention_datetime timestamp with time zone, p_notes text, p_services jsonb, p_products jsonb, p_combos jsonb, p_payments jsonb, p_tenant_id uuid, p_platform_id uuid, p_branch_id uuid, p_total_amount numeric)
 RETURNS uuid
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_attention_id uuid;
    v_service jsonb;
    v_product jsonb;
    v_combo jsonb;
    v_attention_combo_id uuid;
    v_recalculated_total numeric := 0;
BEGIN
    IF jsonb_array_length(p_services) > 0 THEN
        FOR v_service IN SELECT * FROM jsonb_array_elements(p_services) LOOP
            v_recalculated_total := v_recalculated_total + COALESCE((v_service->>'price')::numeric, 0);
        END LOOP;
    END IF;
    IF jsonb_array_length(p_products) > 0 THEN
        FOR v_product IN SELECT * FROM jsonb_array_elements(p_products) LOOP
            v_recalculated_total := v_recalculated_total + (COALESCE((v_product->>'unit_price')::numeric, 0) * COALESCE((v_product->>'quantity')::integer, 1));
        END LOOP;
    END IF;
    IF jsonb_array_length(p_combos) > 0 THEN
        FOR v_combo IN SELECT * FROM jsonb_array_elements(p_combos) LOOP
            v_recalculated_total := v_recalculated_total + COALESCE((v_combo->>'price')::numeric, 0);
        END LOOP;
    END IF;

    INSERT INTO public.attentions (client_id, attention_datetime, notes, total_amount, tenant_id, platform_id, branch_id, status)
    VALUES (p_client_id, p_attention_datetime, p_notes, v_recalculated_total, p_tenant_id, p_platform_id, p_branch_id, 'Pendiente')
    RETURNING id INTO v_attention_id;

    IF jsonb_array_length(p_combos) > 0 THEN
        FOR v_combo IN SELECT * FROM jsonb_array_elements(p_combos) LOOP
            INSERT INTO public.attention_combos (
                attention_id, combo_id, price, quantity, notes, tenant_id, platform_id, branch_id, status
            ) VALUES (
                v_attention_id, (v_combo->>'combo_id')::uuid, COALESCE((v_combo->>'price')::numeric, 0), 
                COALESCE((v_combo->>'quantity')::integer, 1), v_combo->>'notes', p_tenant_id, p_platform_id, p_branch_id, 'Pendiente'
            ) RETURNING id INTO v_attention_combo_id;
        END LOOP;
    END IF;

    IF jsonb_array_length(p_services) > 0 THEN
        FOR v_service IN SELECT * FROM jsonb_array_elements(p_services) LOOP
            SELECT ac.id INTO v_attention_combo_id FROM public.attention_combos ac 
            WHERE ac.attention_id = v_attention_id AND ac.combo_id = (v_service->>'combo_id')::uuid AND ac.tenant_id = p_tenant_id AND ac.platform_id = p_platform_id;
            
            INSERT INTO public.attention_services (
                attention_id, service_id, user_id, service_price, notes, tenant_id, platform_id, branch_id, 
                duration_minutes, start_time, end_time, is_parallel, offset_minutes, status, combo_id, client_treatment_session_id
            ) VALUES (
                v_attention_id, (v_service->>'service_id')::uuid, (v_service->>'user_id')::uuid,
                COALESCE((v_service->>'price')::numeric, 0), v_service->>'notes', p_tenant_id, p_platform_id, p_branch_id, 
                (v_service->>'duration')::integer, (v_service->>'start_time')::time, (v_service->>'end_time')::time,
                (v_service->>'is_parallel')::boolean, (v_service->>'offset_minutes')::integer, 'Pendiente',
                v_attention_combo_id, (v_service->>'client_treatment_session_id')::uuid
            );
        END LOOP;
    END IF;

    IF jsonb_array_length(p_products) > 0 THEN
        FOR v_product IN SELECT * FROM jsonb_array_elements(p_products) LOOP
            SELECT ac.id INTO v_attention_combo_id FROM public.attention_combos ac 
            WHERE ac.attention_id = v_attention_id AND ac.combo_id = (v_product->>'combo_id')::uuid AND ac.tenant_id = p_tenant_id AND ac.platform_id = p_platform_id;
            
            INSERT INTO public.attention_products (
                attention_id, product_id, user_id, quantity, unit_price, total_price, tenant_id, platform_id, branch_id, combo_id, client_treatment_session_id
            ) VALUES (
                v_attention_id, (v_product->>'product_id')::uuid, (v_product->>'user_id')::uuid, 
                COALESCE((v_product->>'quantity')::integer, 1), COALESCE((v_product->>'unit_price')::numeric, 0), 
                COALESCE((v_product->>'unit_price')::numeric, 0) * COALESCE((v_product->>'quantity')::integer, 1), 
                p_tenant_id, p_platform_id, p_branch_id, v_attention_combo_id, (v_product->>'client_treatment_session_id')::uuid
            );
        END LOOP;
    END IF;

    UPDATE public.client_treatment_sessions
    SET
        status = 'Cita Asignada',
        attention_id = v_attention_id
    WHERE id IN (
        SELECT (value->>'client_treatment_session_id')::uuid
        FROM jsonb_array_elements(p_services) AS value
        WHERE value->>'client_treatment_session_id' IS NOT NULL
        UNION
        SELECT (value->>'client_treatment_session_id')::uuid
        FROM jsonb_array_elements(p_products) AS value
        WHERE value->>'client_treatment_session_id' IS NOT NULL
    ) AND tenant_id = p_tenant_id AND platform_id = p_platform_id;

    RETURN v_attention_id;
END;
$function$;

--------------------------------------------------------------------------------
-- 12. get_attentions_with_details
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_attentions_with_details(uuid, uuid, uuid, text, date, date);
CREATE OR REPLACE FUNCTION public.get_attentions_with_details(p_tenant_id uuid, p_platform_id uuid, p_branch_id uuid, p_user_id uuid, p_status_filter text, p_start_date date, p_end_date date)
 RETURNS TABLE(id uuid, created_at timestamp with time zone, tenant_id uuid, platform_id uuid, branch_id uuid, client_id uuid, attention_datetime timestamp with time zone, status text, notes text, total_amount numeric, informed_consent_id uuid, survey_token uuid, survey_status text, clients json, attention_services json, attention_products json, attention_combos json, attention_payments json)
 LANGUAGE plpgsql
AS $function$
BEGIN
  RETURN QUERY
  WITH tenant_users AS (
    SELECT * FROM get_tenant_users(p_tenant_id, p_platform_id)
  ),
  attentions_filtered AS (
    SELECT
      a.id, a.created_at, a.tenant_id, a.platform_id, a.branch_id, a.client_id, a.attention_datetime, a.status, a.notes, a.total_amount,
      sc.id as informed_consent_id, ss.survey_token, ss.status as survey_status
    FROM public.attentions a
    LEFT JOIN public.signed_consents sc ON a.id = sc.attention_id AND a.tenant_id = sc.tenant_id AND a.platform_id = sc.platform_id
    LEFT JOIN public.satisfaction_surveys ss ON a.id = ss.attention_id AND a.tenant_id = ss.tenant_id AND a.platform_id = ss.platform_id
    WHERE
      a.tenant_id = p_tenant_id
      AND a.platform_id = p_platform_id
      AND (p_branch_id IS NULL OR a.branch_id = p_branch_id)
      AND (p_status_filter IS NULL OR a.status = p_status_filter)
      AND (a.attention_datetime::date BETWEEN p_start_date AND p_end_date)
      AND (p_user_id IS NULL OR EXISTS (
        SELECT 1 FROM public.attention_services aserv WHERE aserv.attention_id = a.id AND aserv.user_id = p_user_id AND aserv.tenant_id = p_tenant_id AND aserv.platform_id = p_platform_id
      ))
  )
  SELECT
    af.id, af.created_at, af.tenant_id, af.platform_id, af.branch_id, af.client_id, af.attention_datetime, af.status, af.notes, af.total_amount,
    af.informed_consent_id, af.survey_token, af.survey_status,
    (SELECT json_build_object('id', c.id, 'name', c.name, 'phone', c.phone) FROM public.clients c WHERE c.id = af.client_id AND c.tenant_id = p_tenant_id AND c.platform_id = p_platform_id LIMIT 1) as clients,
    
    (SELECT json_agg(json_build_object(
        'id', aserv.id, 
        'service_id', aserv.service_id, 
        'user_id', aserv.user_id, 
        'service_price', aserv.service_price, 
        'notes', aserv.notes, 
        'status', aserv.status, 
        'attention_combo_id', aserv.combo_id,
        'is_parallel', aserv.is_parallel,
        'offset_minutes', aserv.offset_minutes,
        'duration_minutes', aserv.duration_minutes,
        'services', (SELECT json_build_object('id', s.id, 'name', s.name) FROM public.services s WHERE s.id = aserv.service_id AND s.tenant_id = p_tenant_id AND s.platform_id = p_platform_id),
        'users', (SELECT json_build_object('first_name', tu.first_name, 'last_name', tu.last_name) FROM tenant_users tu WHERE tu.user_id = aserv.user_id LIMIT 1),
        'status_history', (SELECT json_agg(h.*) FROM public.attention_service_status_history h WHERE h.attention_service_id = aserv.id AND h.tenant_id = p_tenant_id AND h.platform_id = p_platform_id),
        'survey_rating', (
          SELECT json_build_object('rating', ssr.rating, 'comments', ssr.comments)
          FROM public.satisfaction_surveys ss
          JOIN public.satisfaction_survey_ratings ssr ON ss.id = ssr.survey_id AND ss.tenant_id = ssr.tenant_id AND ss.platform_id = ssr.platform_id
          WHERE ss.attention_id = af.id AND ssr.attention_service_id = aserv.id AND ss.tenant_id = p_tenant_id AND ss.platform_id = p_platform_id
          LIMIT 1
        )
    )) 
    FROM public.attention_services aserv 
    WHERE aserv.attention_id = af.id AND aserv.tenant_id = p_tenant_id AND aserv.platform_id = p_platform_id) as attention_services,
    
    (SELECT json_agg(json_build_object(
        'id', ap.id, 
        'product_id', ap.product_id, 
        'user_id', ap.user_id, 
        'quantity', ap.quantity, 
        'unit_price', ap.unit_price, 
        'total_price', ap.total_price, 
        'attention_combo_id', ap.combo_id,
        'products', (SELECT json_build_object('id', prod.id, 'name', prod.name) FROM public.products prod WHERE prod.id = ap.product_id AND prod.tenant_id = p_tenant_id AND prod.platform_id = p_platform_id),
        'users', (SELECT json_build_object('first_name', tu.first_name, 'last_name', tu.last_name) FROM tenant_users tu WHERE tu.user_id = ap.user_id LIMIT 1)
    )) 
    FROM public.attention_products ap WHERE ap.attention_id = af.id AND ap.tenant_id = p_tenant_id AND ap.platform_id = p_platform_id) as attention_products,
    
    (SELECT json_agg(json_build_object(
        'id', ac.id, 
        'combo_id', ac.combo_id, 
        'price', ac.price, 
        'quantity', ac.quantity, 
        'status', ac.status,
        'combos', (SELECT json_build_object(
            'id', comb.id, 
            'name', comb.name,
            'duration_minutes', (SELECT SUM(s.duration_minutes) FROM public.combo_items ci JOIN public.services s ON ci.service_id = s.id AND ci.tenant_id = s.tenant_id AND ci.platform_id = s.platform_id WHERE ci.combo_id = comb.id AND ci.tenant_id = p_tenant_id AND ci.platform_id = p_platform_id),
            'combo_items', (SELECT json_agg(json_build_object(
                'id', ci.id, 
                'product_id', ci.product_id, 
                'service_id', ci.service_id, 
                'quantity', ci.quantity, 
                'product', (SELECT json_build_object('name', pr.name) FROM public.products pr WHERE pr.id = ci.product_id AND pr.tenant_id = p_tenant_id AND pr.platform_id = p_platform_id), 
                'service', (SELECT json_build_object('name', se.name, 'duration_minutes', se.duration_minutes) FROM public.services se WHERE se.id = ci.service_id AND se.tenant_id = p_tenant_id AND se.platform_id = p_platform_id)
            )) 
            FROM public.combo_items ci WHERE ci.combo_id = comb.id AND ci.tenant_id = p_tenant_id AND ci.platform_id = p_platform_id)
        ) 
        FROM public.combos comb WHERE comb.id = ac.combo_id AND comb.tenant_id = p_tenant_id AND comb.platform_id = p_platform_id)
    )) 
    FROM public.attention_combos ac WHERE ac.attention_id = af.id AND ac.tenant_id = p_tenant_id AND ac.platform_id = p_platform_id) as attention_combos,

    (SELECT json_agg(DISTINCT pay.*)
    FROM public.attention_payments pay WHERE pay.attention_id = af.id AND pay.tenant_id = p_tenant_id AND pay.platform_id = p_platform_id) as attention_payments

  FROM attentions_filtered af
  ORDER BY af.attention_datetime DESC;
END;
$function$;

--------------------------------------------------------------------------------
-- 13. get_stock_report (Variants)
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_stock_report(uuid);
CREATE OR REPLACE FUNCTION public.get_stock_report(p_tenant_id uuid, p_platform_id uuid)
 RETURNS TABLE(branch_name text, product_name text, quantity numeric, cost numeric, stock_value numeric)
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN QUERY
    SELECT
        b.name as branch_name,
        p.name as product_name,
        bp.stock_quantity as quantity,
        bp.cost_price as cost,
        (bp.stock_quantity * bp.cost_price) as stock_value
    FROM public.branch_products bp
    JOIN public.products p ON bp.product_id = p.id AND bp.tenant_id = p.tenant_id AND bp.platform_id = p.platform_id
    JOIN public.branches b ON bp.branch_id = b.id AND bp.tenant_id = b.tenant_id AND bp.platform_id = b.platform_id
    WHERE bp.tenant_id = p_tenant_id AND bp.platform_id = p_platform_id;
END;
$function$;

DROP FUNCTION IF EXISTS public.get_stock_report(uuid, text, text);
CREATE OR REPLACE FUNCTION public.get_stock_report(p_tenant_id uuid, p_platform_id uuid, p_date_from text, p_date_to text)
 RETURNS TABLE(branch_name text, product_name text, quantity numeric, cost numeric, stock_value numeric)
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN QUERY
    SELECT
        b.name AS branch_name,
        p.name AS product_name,
        bp.stock_quantity AS quantity,
        bp.cost_price AS cost,
        (bp.stock_quantity * bp.cost_price) AS stock_value
    FROM
        branch_products bp
    JOIN
        branches b ON bp.branch_id = b.id AND bp.tenant_id = b.tenant_id AND bp.platform_id = b.platform_id
    JOIN
        products p ON bp.product_id = p.id AND bp.tenant_id = p.tenant_id AND bp.platform_id = p.platform_id
    WHERE
        bp.tenant_id = p_tenant_id
        AND bp.platform_id = p_platform_id
        AND bp.updated_at >= TO_TIMESTAMP(p_date_from, 'YYYY-MM-DD')
        AND bp.updated_at <= TO_TIMESTAMP(p_date_to, 'YYYY-MM-DD')
    ORDER BY
        b.name, p.name;
END;
$function$;

--------------------------------------------------------------------------------
-- 14. get_user_performance_report
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_user_performance_report(uuid, date, date);
CREATE OR REPLACE FUNCTION public.get_user_performance_report(p_tenant_id uuid, p_platform_id uuid, p_date_from date, p_date_to date)
 RETURNS TABLE(user_name text, attentions_count bigint, services_revenue numeric, products_revenue numeric)
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN QUERY
    SELECT
        u.first_name || ' ' || u.last_name as user_name,
        COUNT(DISTINCT a.id) as attentions_count,
        COALESCE(SUM(aserv.service_price), 0) as services_revenue,
        COALESCE(SUM(ap.total_price), 0) as products_revenue
    FROM public.get_tenant_users(p_tenant_id, p_platform_id) u
    LEFT JOIN public.attention_services aserv ON u.user_id = aserv.user_id AND aserv.tenant_id = p_tenant_id AND aserv.platform_id = p_platform_id
    LEFT JOIN public.attentions a ON aserv.attention_id = a.id AND a.tenant_id = p_tenant_id AND a.platform_id = p_platform_id AND a.attention_datetime::date BETWEEN p_date_from AND p_date_to
    LEFT JOIN public.attention_products ap ON u.user_id = ap.user_id AND ap.tenant_id = p_tenant_id AND ap.platform_id = p_platform_id AND ap.attention_id = a.id
    WHERE u.status = 'active'
    GROUP BY u.user_id, u.first_name, u.last_name;
END;
$function$;

--------------------------------------------------------------------------------
-- 15. get_dashboard_stats
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_dashboard_stats(uuid, uuid, uuid, text);
CREATE OR REPLACE FUNCTION public.get_dashboard_stats(p_tenant_id uuid, p_platform_id uuid, p_branch_id uuid, p_user_id uuid, p_timezone text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_stats jsonb;
    v_today date := (NOW() AT TIME ZONE p_timezone)::date;
    v_yesterday date := v_today - INTERVAL '1 day';
    v_start_of_this_month timestamptz := date_trunc('month', NOW() AT TIME ZONE p_timezone);
    v_start_of_last_month timestamptz := v_start_of_this_month - INTERVAL '1 month';
BEGIN
    WITH base_attentions AS (
        SELECT
            a.id,
            a.total_amount,
            a.attention_datetime,
            (a.attention_datetime AT TIME ZONE p_timezone)::date as local_attention_date,
            a.status
        FROM public.attentions a
        WHERE a.tenant_id = p_tenant_id AND a.platform_id = p_platform_id
          AND (p_branch_id IS NULL OR a.branch_id = p_branch_id)
          AND (
              p_user_id IS NULL
              OR EXISTS (
                  SELECT 1 FROM public.attention_services s
                  WHERE s.attention_id = a.id AND s.user_id = p_user_id AND s.tenant_id = p_tenant_id AND s.platform_id = p_platform_id
              )
              OR EXISTS (
                  SELECT 1 FROM public.attention_products p
                  WHERE p.attention_id = a.id AND p.user_id = p_user_id AND p.tenant_id = p_tenant_id AND p.platform_id = p_platform_id
              )
          )
    ),
    paid_attentions AS (
        SELECT * FROM base_attentions
        WHERE status IN ('Finalizada', 'Pagada')
    )
    SELECT jsonb_build_object(
        'todayRevenue', (SELECT COALESCE(SUM(total_amount), 0) FROM paid_attentions WHERE local_attention_date = v_today),
        'monthlyRevenue', (SELECT COALESCE(SUM(total_amount), 0) FROM paid_attentions WHERE attention_datetime >= v_start_of_this_month AND attention_datetime < v_start_of_this_month + INTERVAL '1 month'),
        'todayAppointments', (SELECT COALESCE(COUNT(*), 0) FROM base_attentions WHERE local_attention_date = v_today),
        'activeStylists', (
            SELECT COUNT(DISTINCT user_id)
            FROM public.get_tenant_users(p_tenant_id, p_platform_id)
            WHERE status = 'active' AND is_schedulable = TRUE AND (p_branch_id IS NULL OR branch_id = p_branch_id)
        ),
        'revenueChange', (
            SELECT COALESCE(((today.revenue - yesterday.revenue) / NULLIF(yesterday.revenue, 0) * 100), 0)
            FROM
                (SELECT COALESCE(SUM(total_amount), 0) as revenue FROM paid_attentions WHERE local_attention_date = v_today) today,
                (SELECT COALESCE(SUM(total_amount), 0) as revenue FROM paid_attentions WHERE local_attention_date = v_yesterday) yesterday
        ),
        'appointmentsChange', (
            SELECT COALESCE(((today.count - yesterday.count) / NULLIF(yesterday.count, 0) * 100), 0)
            FROM
                (SELECT COALESCE(COUNT(*), 0) as count FROM base_attentions WHERE local_attention_date = v_today) today,
                (SELECT COALESCE(COUNT(*), 0) as count FROM base_attentions WHERE local_attention_date = v_yesterday) yesterday
        ),
        'monthlyRevenueChange', (
            SELECT COALESCE(((this_month.revenue - last_month.revenue) / NULLIF(last_month.revenue, 0) * 100), 0)
            FROM
                (SELECT COALESCE(SUM(total_amount), 0) as revenue FROM paid_attentions WHERE attention_datetime >= v_start_of_this_month AND attention_datetime < v_start_of_this_month + INTERVAL '1 month') this_month,
                (SELECT COALESCE(SUM(total_amount), 0) as revenue FROM paid_attentions WHERE attention_datetime >= v_start_of_last_month AND attention_datetime < v_start_of_this_month) last_month
        )
    ) INTO v_stats;

    RETURN v_stats;
END;
$function$;

--------------------------------------------------------------------------------
-- 16. process_sale_from_attention
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.process_sale_from_attention(uuid);
CREATE OR REPLACE FUNCTION public.process_sale_from_attention(p_tenant_id uuid, p_platform_id uuid, p_attention_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    attention_rec RECORD;
    sale_id_new uuid;
    sale_number_new text;
    service_item RECORD;
    product_item RECORD;
    new_sales_item_id uuid;
    total_subtotal_amt numeric;
    total_tax_amt numeric;
    total_amt numeric;
    product_cost numeric;
    v_staff_user_id uuid;
    v_commission_rate numeric;
    v_commission_amount numeric;
    v_rate_source text;
    v_commissions_array JSONB[] := '{}'::JSONB[];
BEGIN
    SELECT * INTO attention_rec FROM public.attentions WHERE id = p_attention_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;

    sale_number_new := public.get_next_document_number(p_tenant_id, 'SALE'::text, attention_rec.branch_id, '{}'::jsonb);

    INSERT INTO public.sales (tenant_id, platform_id, branch_id, client_id, attention_id, sale_number, sale_date, subtotal_amount, total_tax_amount, total_amount, status)
    VALUES (p_tenant_id, p_platform_id, attention_rec.branch_id, attention_rec.client_id, p_attention_id, sale_number_new, now(), 0, 0, 0, 'COMPLETED')
    RETURNING id INTO sale_id_new;

    FOR service_item IN
        SELECT ats.id as attention_service_id, s.name as service_name, s.id as service_id, ats.service_price, ats.user_id
        FROM public.attention_services ats JOIN public.services s ON ats.service_id = s.id AND ats.tenant_id = s.tenant_id AND ats.platform_id = s.platform_id
        WHERE ats.attention_id = p_attention_id AND ats.combo_id IS NULL AND ats.tenant_id = p_tenant_id AND ats.platform_id = p_platform_id
    LOOP
        INSERT INTO public.sales_items (sale_id, tenant_id, platform_id, item_type, service_id, description, quantity, unit_price, subtotal_price, total_tax_amount, total_price)
        VALUES (sale_id_new, p_tenant_id, p_platform_id, 'SERVICE', service_item.service_id, service_item.service_name, 1, service_item.service_price, service_item.service_price, 0, service_item.service_price)
        RETURNING id INTO new_sales_item_id;

        v_staff_user_id := service_item.user_id;
        IF v_staff_user_id IS NOT NULL THEN
            SELECT commission_rate INTO v_commission_rate FROM public.service_user_commissions
            WHERE service_id = service_item.service_id AND user_id = v_staff_user_id AND branch_id = attention_rec.branch_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;
            v_rate_source := 'service_specific';

            IF NOT FOUND OR v_commission_rate = 0 THEN
                SELECT default_service_commission_rate INTO v_commission_rate FROM public.user_assignments
                WHERE user_id = v_staff_user_id AND branch_id = attention_rec.branch_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;
                v_rate_source := 'user_default';
            END IF;

            IF FOUND AND v_commission_rate > 0 THEN
                v_commission_amount := service_item.service_price * (v_commission_rate / 100.0);
                INSERT INTO public.earned_commissions (tenant_id, platform_id, branch_id, user_id, sale_id, sales_item_id, commission_amount, commission_rate_used, source_of_rate)
                VALUES (p_tenant_id, p_platform_id, attention_rec.branch_id, v_staff_user_id, sale_id_new, new_sales_item_id, v_commission_amount, v_commission_rate, v_rate_source);
                
                v_commissions_array := v_commissions_array || jsonb_build_object('user_id', v_staff_user_id, 'amount', v_commission_amount, 'item_name', service_item.service_name);
            END IF;
        END IF;
    END LOOP;

    FOR product_item IN
        SELECT p.name as product_name, p.id as product_id, atp.unit_price, atp.quantity, atp.user_id
        FROM public.attention_products atp JOIN public.products p ON atp.product_id = p.id AND atp.tenant_id = p.tenant_id AND atp.platform_id = p.platform_id
        WHERE atp.attention_id = p_attention_id AND atp.combo_id IS NULL AND atp.tenant_id = p_tenant_id AND atp.platform_id = p_platform_id
    LOOP
        INSERT INTO public.sales_items (sale_id, tenant_id, platform_id, item_type, product_id, description, quantity, unit_price, subtotal_price, total_tax_amount, total_price)
        VALUES (sale_id_new, p_tenant_id, p_platform_id, 'PRODUCT', product_item.product_id, product_item.product_name, product_item.quantity, product_item.unit_price, product_item.unit_price * product_item.quantity, 0, product_item.unit_price * product_item.quantity)
        RETURNING id INTO new_sales_item_id;

        v_staff_user_id := product_item.user_id;
        IF v_staff_user_id IS NOT NULL THEN
            SELECT commission_rate INTO v_commission_rate FROM public.product_user_commissions
            WHERE product_id = product_item.product_id AND user_id = v_staff_user_id AND branch_id = attention_rec.branch_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;
            v_rate_source := 'product_specific';

            IF NOT FOUND OR v_commission_rate = 0 THEN
                SELECT default_product_commission_rate INTO v_commission_rate FROM public.user_assignments
                WHERE user_id = v_staff_user_id AND branch_id = attention_rec.branch_id AND tenant_id = p_tenant_id AND platform_id = p_platform_id;
                v_rate_source := 'user_default';
            END IF;

            IF FOUND AND v_commission_rate > 0 THEN
                v_commission_amount := (product_item.unit_price * product_item.quantity) * (v_commission_rate / 100.0);
                INSERT INTO public.earned_commissions (tenant_id, platform_id, branch_id, user_id, sale_id, sales_item_id, commission_amount, commission_rate_used, source_of_rate)
                VALUES (p_tenant_id, p_platform_id, attention_rec.branch_id, v_staff_user_id, sale_id_new, new_sales_item_id, v_commission_amount, v_commission_rate, v_rate_source);

                v_commissions_array := v_commissions_array || jsonb_build_object('user_id', v_staff_user_id, 'amount', v_commission_amount, 'item_name', product_item.product_name);
            END IF;
        END IF;

        SELECT cost_price INTO product_cost FROM public.branch_products bp WHERE bp.product_id = product_item.product_id AND bp.branch_id = attention_rec.branch_id AND bp.tenant_id = p_tenant_id AND bp.platform_id = p_platform_id;
        PERFORM public.create_product_movement(p_tenant_id, p_platform_id, attention_rec.branch_id, product_item.product_id, 'SALE'::text, -product_item.quantity, COALESCE(product_cost, 0), sale_id_new, 'SALE'::text);
    END LOOP;

    SELECT COALESCE(SUM(total_price), 0), COALESCE(SUM(subtotal_price), 0), COALESCE(SUM(total_tax_amount), 0)
    INTO total_amt, total_subtotal_amt, total_tax_amt
    FROM public.sales_items WHERE sale_id = sale_id_new AND tenant_id = p_tenant_id AND platform_id = p_platform_id;

    UPDATE public.sales SET total_amount = total_amt, subtotal_amount = total_subtotal_amt, total_tax_amount = total_tax_amt
    WHERE id = sale_id_new AND tenant_id = p_tenant_id AND platform_id = p_platform_id;

    RETURN jsonb_build_object(
        'saleId', sale_id_new,
        'commissions', v_commissions_array
    );
END;
$function$;

--------------------------------------------------------------------------------
-- 17. get_pending_commissions
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_pending_commissions(uuid, uuid, uuid);
CREATE OR REPLACE FUNCTION public.get_pending_commissions(p_tenant_id uuid, p_platform_id uuid, p_branch_id uuid DEFAULT NULL::uuid, p_user_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(total_pending_commissions numeric)
 LANGUAGE plpgsql
AS $function$
BEGIN
  RETURN QUERY
  SELECT
    COALESCE(SUM(commission_amount), 0)
  FROM
    public.earned_commissions
  WHERE
    tenant_id = p_tenant_id
    AND platform_id = p_platform_id
    AND status = 'earned'
    AND (p_branch_id IS NULL OR branch_id = p_branch_id)
    AND (p_user_id IS NULL OR user_id = p_user_id);
END;
$function$;

--------------------------------------------------------------------------------
-- 18. get_today_attentions
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_today_attentions(uuid, uuid, uuid, text);
CREATE OR REPLACE FUNCTION public.get_today_attentions(p_tenant_id uuid, p_platform_id uuid, p_branch_id uuid, p_user_id uuid, p_timezone text)
 RETURNS TABLE(id uuid, attention_time text, client_name text, services jsonb, stylists jsonb, status text, total_price numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_today date := (NOW() AT TIME ZONE p_timezone)::date;
BEGIN
    RETURN QUERY
    WITH base_attentions AS (
        SELECT a.*
        FROM public.attentions a
        WHERE
            a.tenant_id = p_tenant_id AND a.platform_id = p_platform_id
            AND (a.attention_datetime AT TIME ZONE p_timezone)::date = v_today
            AND a.status IN ('Pendiente', 'Confirmada')
            AND (p_branch_id IS NULL OR a.branch_id = p_branch_id)
            AND (p_user_id IS NULL OR EXISTS (
                SELECT 1 FROM public.attention_services s_asgn
                WHERE s_asgn.attention_id = a.id AND s_asgn.user_id = p_user_id AND s_asgn.tenant_id = p_tenant_id AND s_asgn.platform_id = p_platform_id
            ))
    ),
    aggregated_data AS (
        SELECT
            aserv.attention_id,
            jsonb_agg(DISTINCT jsonb_build_object('id', s.id, 'name', s.name)) as services,
            jsonb_agg(DISTINCT jsonb_build_object('id', u.user_id, 'name', u.first_name || ' ' || u.last_name)) as stylists
        FROM public.attention_services aserv
        JOIN base_attentions ba ON aserv.attention_id = ba.id
        JOIN public.services s ON aserv.service_id = s.id AND aserv.tenant_id = s.tenant_id AND aserv.platform_id = s.platform_id
        JOIN public.get_tenant_users(p_tenant_id, p_platform_id) u ON aserv.user_id = u.user_id
        WHERE aserv.tenant_id = p_tenant_id AND aserv.platform_id = p_platform_id
        GROUP BY aserv.attention_id
    )
    SELECT
        ba.id,
        to_char(ba.attention_datetime AT TIME ZONE p_timezone, 'HH24:MI') as attention_time,
        c.name as client_name,
        agd.services,
        agd.stylists,
        ba.status,
        ba.total_amount as total_price
    FROM
        base_attentions ba
    JOIN
        public.clients c ON ba.client_id = c.id AND ba.tenant_id = c.tenant_id AND ba.platform_id = c.platform_id
    LEFT JOIN
        aggregated_data agd ON ba.id = agd.attention_id
    ORDER BY
        ba.attention_datetime;
END;
$function$;

--------------------------------------------------------------------------------
-- 19. get_top_services
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_top_services(uuid, uuid, uuid, integer, text);
CREATE OR REPLACE FUNCTION public.get_top_services(p_tenant_id uuid, p_platform_id uuid, p_branch_id uuid, p_user_id uuid, p_days integer, p_timezone text)
 RETURNS TABLE(name text, count bigint, revenue numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_start_date timestamptz := (NOW() AT TIME ZONE p_timezone) - (p_days || ' days')::interval;
BEGIN
    RETURN QUERY
    SELECT
        s.name,
        COUNT(aserv.id)::bigint as count,
        SUM(aserv.service_price) as revenue
    FROM
        public.attention_services aserv
    JOIN
        public.services s ON aserv.service_id = s.id AND aserv.tenant_id = s.tenant_id AND aserv.platform_id = s.platform_id
    JOIN
        public.attentions a ON aserv.attention_id = a.id AND aserv.tenant_id = a.tenant_id AND aserv.platform_id = a.platform_id
    WHERE
        a.tenant_id = p_tenant_id
        AND a.platform_id = p_platform_id
        AND a.attention_datetime >= v_start_date
        AND a.status IN ('Pagada', 'Finalizada')
        AND (p_branch_id IS NULL OR a.branch_id = p_branch_id)
        AND (p_user_id IS NULL OR aserv.user_id = p_user_id)
    GROUP BY
        s.name
    ORDER BY
        count DESC
    LIMIT 5;
END;
$function$;

COMMIT;
