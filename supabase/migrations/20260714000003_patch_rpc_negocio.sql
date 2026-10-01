-- Parche de 18 Funciones de Negocio para añadir p_platform_id y filtrar

DROP FUNCTION IF EXISTS "public"."add_turn"("uuid", "uuid", "uuid");
CREATE OR REPLACE FUNCTION "public"."add_turn"("p_branch_id" "uuid", "p_client_id" "uuid", "p_stylist_id" "uuid", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS "uuid"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  v_tenant_id uuid;
  v_turn_id uuid;
BEGIN
  v_tenant_id := auth.get_tenant_id_from_jwt();

  INSERT INTO turns (branch_id, client_id, stylist_id, status, tenant_id, platform_id)
  VALUES (p_branch_id, p_client_id, p_stylist_id, 'waiting', v_tenant_id, p_platform_id)
  RETURNING id INTO v_turn_id;

  RETURN v_turn_id;
END;
$$;

DROP FUNCTION IF EXISTS "public"."assign_equipment_to_user"("uuid", "uuid", "uuid", "date");
CREATE OR REPLACE FUNCTION "public"."assign_equipment_to_user"("p_equipment_id" "uuid", "p_user_id" "uuid", "p_branch_id" "uuid", "p_assignment_date" "date", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS "uuid"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    new_assignment_id uuid;
BEGIN
    INSERT INTO equipment_assignments (equipment_id, user_id, branch_id, assignment_date)
    VALUES (p_equipment_id, p_user_id, p_branch_id, p_assignment_date)
    RETURNING id INTO new_assignment_id;
    RETURN new_assignment_id;
END;
$$;

DROP FUNCTION IF EXISTS "public"."call_turn"("uuid");
CREATE OR REPLACE FUNCTION "public"."call_turn"("p_turn_id" "uuid", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  UPDATE turns
  SET
    status = 'called',
    called_at = now()
  WHERE id = p_turn_id;
END;
$$;

DROP FUNCTION IF EXISTS "public"."cancel_attention_and_notify"("uuid");
CREATE OR REPLACE FUNCTION "public"."cancel_attention_and_notify"("p_attention_id" "uuid", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_attention RECORD;
BEGIN
    -- Step 1: Get attention details for the notification
    SELECT tenant_id, client_id INTO v_attention FROM public.attentions WHERE id = p_attention_id;

    IF v_attention IS NULL THEN
        RAISE EXCEPTION 'Attention with ID % not found.', p_attention_id;
    END IF;

    -- Step 2: Update the attention status
    UPDATE public.attentions
    SET status = 'Cancelada'
    WHERE id = p_attention_id;

    -- Step 3: Enqueue client notifications for the cancellation
    BEGIN
        -- Email Notification
        PERFORM public.queue_client_email(
            p_tenant_id := v_attention.tenant_id,
            p_client_id := v_attention.client_id,
            p_template_type := 'attention_cancelled',
            p_template_data := '{}'::jsonb
        );
    EXCEPTION
        WHEN others THEN
            RAISE WARNING 'Failed to queue client cancellation email for attention_id %: %', p_attention_id, SQLERRM;
    END;

    BEGIN
        -- WhatsApp Notification
        PERFORM public.queue_client_whatsapp(
            p_tenant_id := v_attention.tenant_id,
            p_client_id := v_attention.client_id,
            p_template_name := 'attention_cancelled_whatsapp',
            p_template_params := '{}'::jsonb
        );
    EXCEPTION
        WHEN others THEN
            RAISE WARNING 'Failed to queue client cancellation WhatsApp for attention_id %: %', p_attention_id, SQLERRM;
    END;

END;
$$;

DROP FUNCTION IF EXISTS "public"."confirm_attention"("uuid");
CREATE OR REPLACE FUNCTION "public"."confirm_attention"("p_attention_id" "uuid", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  UPDATE public.attentions
  SET status = 'Confirmada', updated_at = now()
  WHERE id = p_attention_id;
END;
$$;

DROP FUNCTION IF EXISTS "public"."create_equipment"("jsonb");
CREATE OR REPLACE FUNCTION "public"."create_equipment"("p_equipment_data" "jsonb", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS "uuid"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    new_equipment_id uuid;
BEGIN
    INSERT INTO equipment (tenant_id, platform_id, name, type_id, brand_id, model, serial_number, purchase_date, last_maintenance_date, maintenance_frequency, maintenance_frequency_unit, notes, is_active)
    VALUES (
        (p_equipment_data->>'tenant_id')::uuid,
        p_platform_id,
        p_equipment_data->>'name',
        (p_equipment_data->>'type_id')::uuid,
        NULLIF(p_equipment_data->>'brand_id', '')::uuid, -- Solución: Previene error si la marca es opcional
        p_equipment_data->>'model',
        p_equipment_data->>'serial_number',
        NULLIF(p_equipment_data->>'purchase_date', '')::date, -- Solución: Previene error con fechas vacías
        NULLIF(p_equipment_data->>'last_maintenance_date', '')::date, -- Solución: Previene error con fechas vacías
        (p_equipment_data->>'maintenance_frequency')::integer,
        p_equipment_data->>'maintenance_frequency_unit',
        p_equipment_data->>'notes',
        (p_equipment_data->>'is_active')::boolean -- Solución: Añadido para guardar el estado del toggle
    ) RETURNING id INTO new_equipment_id;
    RETURN new_equipment_id;
END;
$$;

DROP FUNCTION IF EXISTS "public"."create_equipment_maintenance_record"("jsonb");
CREATE OR REPLACE FUNCTION "public"."create_equipment_maintenance_record"("p_maintenance_data" "jsonb", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS "uuid"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    new_maintenance_id uuid;
BEGIN
    INSERT INTO equipment_maintenance_history (equipment_id, maintenance_date, notes)
    VALUES (
        (p_maintenance_data->>'equipment_id')::uuid,
        (p_maintenance_data->>'maintenance_date')::date,
        p_maintenance_data->>'notes'
    ) RETURNING id INTO new_maintenance_id;
    RETURN new_maintenance_id;
END;
$$;

DROP FUNCTION IF EXISTS "public"."decrement_stock_from_attention"("uuid");
CREATE OR REPLACE FUNCTION "public"."decrement_stock_from_attention"("p_attention_id" "uuid", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_product RECORD;
    v_branch_id UUID;
BEGIN
    -- Get branch_id from attention
    SELECT branch_id INTO v_branch_id FROM public.attentions WHERE id = p_attention_id;

    -- Loop through products in the attention and decrement stock
    FOR v_product IN
        SELECT * FROM public.attention_products WHERE attention_id = p_attention_id
    LOOP
        UPDATE public.branch_products
        SET stock_quantity = stock_quantity - v_product.quantity
        WHERE branch_id = v_branch_id AND product_id = v_product.product_id;
    END LOOP;
END;
$$;

DROP FUNCTION IF EXISTS "public"."delete_equipment"("uuid");
CREATE OR REPLACE FUNCTION "public"."delete_equipment"("p_equipment_id" "uuid", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    DELETE FROM equipment WHERE id = p_equipment_id;
END;
$$;

DROP FUNCTION IF EXISTS "public"."finish_attention_service"("uuid");
CREATE OR REPLACE FUNCTION "public"."finish_attention_service"("p_attention_service_id" "uuid", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_tenant_id uuid;
    v_branch_id uuid;
    v_user_id uuid;
BEGIN
    -- Obtener IDs necesarios del servicio de atención
    SELECT tenant_id, branch_id, user_id INTO v_tenant_id, v_branch_id, v_user_id
    FROM public.attention_services
    WHERE id = p_attention_service_id;

    -- Actualizar el estado del servicio y la hora de finalización
    UPDATE public.attention_services
    SET 
        status = 'Finalizado',
        end_time = now()
    WHERE id = p_attention_service_id;

    -- Insertar un registro en el historial de estados
    INSERT INTO public.attention_service_status_history
        (attention_service_id, status, tenant_id, branch_id, user_id)
    VALUES
        (p_attention_service_id, 'Finalizado', v_tenant_id, v_branch_id, v_user_id);
END;
$$;

DROP FUNCTION IF EXISTS "public"."finish_service"("uuid");
CREATE OR REPLACE FUNCTION "public"."finish_service"("p_attention_service_id" "uuid", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  UPDATE public.attention_services
  SET
    status = 'Finalizado',
    end_time = CURRENT_TIME
  WHERE
    id = p_attention_service_id
    AND status = 'En Progreso';
END;
$$;

DROP FUNCTION IF EXISTS "public"."reschedule_attention"("uuid", "p_new_datetime" timestamp with time zone, "text", "text", "uuid");
CREATE OR REPLACE FUNCTION "public"."reschedule_attention"("p_attention_id" "uuid", "p_new_datetime" timestamp with time zone, "p_reason" "text", "p_fault" "text", "p_user_id" "uuid", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_original_date TIMESTAMPTZ;
    v_client_id UUID;
BEGIN
    -- Get original date and client_id from the attention
    SELECT attention_datetime, client_id
    INTO v_original_date, v_client_id
    FROM attentions
    WHERE id = p_attention_id;

    -- Update the attention with the new date and time
    UPDATE attentions
    SET attention_datetime = p_new_datetime
    WHERE id = p_attention_id;

    -- Insert a record into the rescheduled_attentions table
    INSERT INTO rescheduled_attentions (attention_id, client_id, original_date, new_date, reason, user_id, fault)
    VALUES (p_attention_id, v_client_id, v_original_date, p_new_datetime, p_reason, p_user_id, p_fault);

END;
$$;

DROP FUNCTION IF EXISTS "public"."return_equipment"("uuid", "date");
CREATE OR REPLACE FUNCTION "public"."return_equipment"("p_assignment_id" "uuid", "p_return_date" "date", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    UPDATE equipment_assignments
    SET
        return_date = p_return_date
    WHERE
        id = p_assignment_id;
END;
$$;

DROP FUNCTION IF EXISTS "public"."start_attention_service"("uuid");
CREATE OR REPLACE FUNCTION "public"."start_attention_service"("p_attention_service_id" "uuid", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_tenant_id uuid;
    v_branch_id uuid;
    v_user_id uuid;
    v_attention_id uuid;
BEGIN
    -- Obtener IDs necesarios del servicio de atención
    SELECT tenant_id, branch_id, user_id, attention_id INTO v_tenant_id, v_branch_id, v_user_id, v_attention_id
    FROM public.attention_services
    WHERE id = p_attention_service_id;

    -- Actualizar el estado del servicio y la hora de inicio
    UPDATE public.attention_services
    SET 
        status = 'En Proceso',
        start_time = now()
    WHERE id = p_attention_service_id;

    -- Insertar un registro en el historial de estados
    INSERT INTO public.attention_service_status_history
        (attention_service_id, status, tenant_id, branch_id, user_id)
    VALUES
        (p_attention_service_id, 'En Proceso', v_tenant_id, v_branch_id, v_user_id);

    -- Actualizar el estado de la atención principal a 'En Proceso' si es la primera
    UPDATE public.attentions
    SET status = 'En Proceso'
    WHERE id = v_attention_id AND status = 'Confirmada';
END;
$$;

DROP FUNCTION IF EXISTS "public"."start_service"("uuid");
CREATE OR REPLACE FUNCTION "public"."start_service"("p_attention_service_id" "uuid", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_tenant_id uuid;
    v_branch_id uuid;
    v_user_id uuid;
    v_attention_id uuid;
BEGIN
    -- Update the service status and start time
    UPDATE public.attention_services
    SET
        status = 'En Proceso',
        start_time = (now() AT TIME ZONE 'UTC')::time
    WHERE id = p_attention_service_id
    RETURNING tenant_id, branch_id, user_id, attention_id INTO v_tenant_id, v_branch_id, v_user_id, v_attention_id;

    -- Insert a record into the status history table
    IF FOUND THEN
        INSERT INTO public.attention_service_status_history
            (attention_service_id, status, tenant_id, branch_id, user_id)
        VALUES
            (p_attention_service_id, 'En Proceso', v_tenant_id, v_branch_id, v_user_id);
        
        -- Update the main attention status to 'En Proceso'
        UPDATE public.attentions
        SET status = 'En Proceso'
        WHERE id = v_attention_id;

        -- Delete the turn from the turns table
        DELETE FROM public.turns
        WHERE attention_id = v_attention_id;
    END IF;
END;
$$;

DROP FUNCTION IF EXISTS "public"."update_equipment"("uuid", "jsonb");
CREATE OR REPLACE FUNCTION "public"."update_equipment"("p_equipment_id" "uuid", "p_equipment_data" "jsonb", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    UPDATE equipment
    SET
        name = COALESCE(p_equipment_data->>'name', name),
        type_id = COALESCE(NULLIF(p_equipment_data->>'type_id', '')::uuid, type_id),
        brand_id = COALESCE(NULLIF(p_equipment_data->>'brand_id', '')::uuid, brand_id),
        model = COALESCE(p_equipment_data->>'model', model),
        serial_number = COALESCE(p_equipment_data->>'serial_number', serial_number),
        purchase_date = COALESCE(NULLIF(p_equipment_data->>'purchase_date', '')::date, purchase_date),
        last_maintenance_date = COALESCE(NULLIF(p_equipment_data->>'last_maintenance_date', '')::date, last_maintenance_date),
        maintenance_frequency = COALESCE((p_equipment_data->>'maintenance_frequency')::integer, maintenance_frequency),
        maintenance_frequency_unit = COALESCE(p_equipment_data->>'maintenance_frequency_unit', maintenance_frequency_unit),
        notes = COALESCE(p_equipment_data->>'notes', notes),
        is_active = COALESCE((p_equipment_data->>'is_active')::boolean, is_active),
        updated_at = now()
    WHERE
        id = p_equipment_id;
END;
$$;

DROP FUNCTION IF EXISTS "public"."update_equipment_maintenance_record"("uuid", "jsonb");
CREATE OR REPLACE FUNCTION "public"."update_equipment_maintenance_record"("p_record_id" "uuid", "p_updates" "jsonb", "p_platform_id" "uuid" DEFAULT NULL::"uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    UPDATE equipment_maintenance_history
    SET
        maintenance_date = COALESCE(NULLIF(p_updates->>'maintenance_date', '')::date, maintenance_date),
        notes = COALESCE(p_updates->>'notes', notes),
        updated_at = now()
    WHERE
        id = p_record_id;
END;
$$;

