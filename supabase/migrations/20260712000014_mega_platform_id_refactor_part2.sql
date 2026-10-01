-- Migration: 20260712000014_mega_platform_id_refactor_part2.sql
-- Description: Adds p_platform_id to all callRpc wrapper functions missed by the first migration.

-- Recreating check_slug_availability
DROP FUNCTION IF EXISTS "public"."check_slug_availability"("params" "jsonb");

CREATE OR REPLACE FUNCTION "public"."check_slug_availability"("params" "jsonb", "p_platform_id" "uuid" DEFAULT NULL::uuid) RETURNS boolean
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    p_slug text := params->>'p_slug';
    p_country_id uuid := (params->>'p_country_id')::uuid;
    p_tenant_id uuid := (params->>'p_tenant_id')::uuid;
    p_platform_id uuid := (params->>'p_platform_id')::uuid;
BEGIN
    IF p_platform_id IS NULL THEN
        SELECT platform_id INTO p_platform_id FROM public.tenants WHERE id = p_tenant_id;
    END IF;

    IF p_platform_id IS NULL THEN
        RAISE EXCEPTION 'Could not determine platform for tenant';
    END IF;

    RETURN NOT EXISTS (
        SELECT 1
        FROM public.tenants
        WHERE slug = p_slug 
          AND country_id = p_country_id
          AND platform_id = p_platform_id
          AND id != p_tenant_id
    );
END;
$$;

-- Recreating set_primary_branch_photo
DROP FUNCTION IF EXISTS "public"."set_primary_branch_photo"("p_tenant_id" "uuid", "p_branch_id" "uuid", "p_photo_id" "uuid");

CREATE OR REPLACE FUNCTION "public"."set_primary_branch_photo"("p_tenant_id" "uuid", "p_branch_id" "uuid", "p_photo_id" "uuid", "p_platform_id" "uuid" DEFAULT NULL::uuid) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    -- First, ensure the photo belongs to the tenant and branch
    IF NOT EXISTS (
        SELECT 1 FROM public.branch_photos
        WHERE id = p_photo_id AND branch_id = p_branch_id AND tenant_id = p_tenant_id
    ) THEN
        RAISE EXCEPTION 'Photo not found or permission denied';
    END IF;

    -- Set all other photos for this branch to not be primary
    UPDATE public.branch_photos
    SET is_primary = false
    WHERE branch_id = p_branch_id
      AND tenant_id = p_tenant_id
      AND is_primary = true;

    -- Set the specified photo as primary
    UPDATE public.branch_photos
    SET is_primary = true,
        updated_at = now()
    WHERE id = p_photo_id;
END;
$$;

-- Recreating delete_branch_photo
DROP FUNCTION IF EXISTS "public"."delete_branch_photo"("p_branch_id" "uuid", "p_photo_id" "uuid", "p_tenant_id" "uuid");

CREATE OR REPLACE FUNCTION "public"."delete_branch_photo"("p_branch_id" "uuid", "p_photo_id" "uuid", "p_tenant_id" "uuid", "p_platform_id" "uuid" DEFAULT NULL::uuid) RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_google_drive_file_id text;
    v_is_primary boolean;
BEGIN
    -- Check if the photo exists, belongs to the tenant/branch, and get its details
    SELECT google_drive_file_id, is_primary
    INTO v_google_drive_file_id, v_is_primary
    FROM public.branch_photos
    WHERE id = p_photo_id AND branch_id = p_branch_id AND tenant_id = p_tenant_id;

    IF v_google_drive_file_id IS NULL THEN
        RAISE EXCEPTION 'Photo not found or permission denied';
    END IF;

    -- If it's the primary photo, check if there are other photos for the branch.
    -- If there are, we might need to automatically set a new primary, or prevent deletion.
    -- Correction: If it's the primary photo AND there are other photos, prevent deletion.
    IF v_is_primary AND (SELECT COUNT(*) FROM public.branch_photos WHERE branch_id = p_branch_id AND id != p_photo_id) > 0 THEN
        RAISE EXCEPTION 'Cannot delete primary photo if other photos exist. Set another photo as primary first.';
    END IF;


    -- Delete the record from the database
    DELETE FROM public.branch_photos
    WHERE id = p_photo_id;

    -- Return the Google Drive File ID so the edge function can delete the file from Drive
    RETURN v_google_drive_file_id;
END;
$$;

-- Recreating get_equipment_types
DROP FUNCTION IF EXISTS "public"."get_equipment_types"("p_tenant_id" "uuid");

CREATE OR REPLACE FUNCTION "public"."get_equipment_types"("p_tenant_id" "uuid", "p_platform_id" "uuid" DEFAULT NULL::uuid) RETURNS TABLE("id" "uuid", "name" "text", "description" "text", "is_active" boolean)
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY
    SELECT et.id, et.name, et.description, et.is_active
    FROM equipment_types et
    WHERE et.tenant_id = p_tenant_id
    ORDER BY et.name;
END;
$$;

-- Recreating create_equipment_type
DROP FUNCTION IF EXISTS "public"."create_equipment_type"("p_tenant_id" "uuid", "p_name" "text", "p_description" "text");

CREATE OR REPLACE FUNCTION "public"."create_equipment_type"("p_tenant_id" "uuid", "p_name" "text", "p_description" "text", "p_platform_id" "uuid" DEFAULT NULL::uuid) RETURNS "uuid"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    new_type_id uuid;
BEGIN
    INSERT INTO equipment_types (tenant_id, name, description)
    VALUES (p_tenant_id, p_name, p_description)
    RETURNING id INTO new_type_id;
    RETURN new_type_id;
END;
$$;

-- Recreating update_equipment_type
DROP FUNCTION IF EXISTS "public"."update_equipment_type"("p_tenant_id" "uuid", "p_type_id" "uuid", "p_name" "text", "p_description" "text", "p_is_active" boolean);

CREATE OR REPLACE FUNCTION "public"."update_equipment_type"("p_tenant_id" "uuid", "p_type_id" "uuid", "p_name" "text", "p_description" "text", "p_is_active" boolean, "p_platform_id" "uuid" DEFAULT NULL::uuid) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    UPDATE equipment_types
    SET
        name = p_name,
        description = p_description,
        is_active = p_is_active,
        updated_at = now()
    WHERE id = p_type_id AND tenant_id = p_tenant_id;
END;
$$;

-- Recreating delete_equipment_type
DROP FUNCTION IF EXISTS "public"."delete_equipment_type"("p_tenant_id" "uuid", "p_type_id" "uuid");

CREATE OR REPLACE FUNCTION "public"."delete_equipment_type"("p_tenant_id" "uuid", "p_type_id" "uuid", "p_platform_id" "uuid" DEFAULT NULL::uuid) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    -- Check if the type is being used by any equipment
    IF EXISTS (SELECT 1 FROM equipment WHERE type_id = p_type_id AND tenant_id = p_tenant_id) THEN
        RAISE EXCEPTION 'Cannot delete equipment type because it is in use.';
    END IF;

    DELETE FROM equipment_types WHERE id = p_type_id AND tenant_id = p_tenant_id;
END;
$$;

-- Recreating get_equipment
DROP FUNCTION IF EXISTS "public"."get_equipment"("p_tenant_id" "uuid", "p_branch_id" "uuid", "p_user_id" "uuid");
DROP FUNCTION IF EXISTS "public"."get_equipment"("p_tenant_id" "uuid", "p_search_term" "text", "p_show_inactive" boolean, "p_type_id" "uuid", "p_brand_id" "uuid");

CREATE OR REPLACE FUNCTION "public"."get_equipment"("p_tenant_id" "uuid", "p_branch_id" "uuid" DEFAULT NULL::"uuid", "p_user_id" "uuid" DEFAULT NULL::"uuid", "p_platform_id" "uuid" DEFAULT NULL::uuid) RETURNS TABLE("id" "uuid", "name" "text", "type_name" "text", "brand" "text", "model" "text", "serial_number" "text", "assigned_user_name" "text", "branch_name" "text")
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        e.id,
        e.name,
        et.name as type_name,
        e.brand,
        e.model,
        e.serial_number,
        u.first_name || ' ' || u.last_name as assigned_user_name,
        b.name as branch_name
    FROM
        equipment e
    LEFT JOIN
        equipment_types et ON e.type_id = et.id
    LEFT JOIN
        equipment_assignments ea ON e.id = ea.equipment_id AND ea.return_date IS NULL
    LEFT JOIN
        users u ON ea.user_id = u.id
    LEFT JOIN
        branches b ON ea.branch_id = b.id
    WHERE
        e.tenant_id = p_tenant_id
        AND (p_branch_id IS NULL OR ea.branch_id = p_branch_id)
        AND (p_user_id IS NULL OR ea.user_id = p_user_id);
END;
$$;

CREATE OR REPLACE FUNCTION "public"."get_equipment"("p_tenant_id" "uuid", "p_search_term" "text" DEFAULT NULL::"text", "p_show_inactive" boolean DEFAULT false, "p_type_id" "uuid" DEFAULT NULL::"uuid", "p_brand_id" "uuid" DEFAULT NULL::"uuid", "p_platform_id" "uuid" DEFAULT NULL::uuid) RETURNS TABLE("id" "uuid", "name" "text", "type_id" "uuid", "brand_id" "uuid", "is_active" boolean, "type_name" "text", "brand_name" "text", "model" "text", "serial_number" "text", "purchase_date" "text", "last_maintenance_date" "text", "maintenance_frequency" integer, "maintenance_frequency_unit" "text", "notes" "text", "assigned_user_name" "text", "branch_name" "text")
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY
    WITH tenant_users AS (
        SELECT
            tu.user_id,
            (tu.first_name || ' ' || tu.last_name) as full_name
        FROM get_tenant_users(p_tenant_id) tu
    )
    SELECT
        e.id,
        e.name,
        e.type_id,
        e.brand_id,
        e.is_active,
        et.name as type_name,
        eb.name as brand_name,
        e.model,
        e.serial_number,
        to_char(e.purchase_date, 'YYYY-MM-DD') as purchase_date,
        to_char(e.last_maintenance_date, 'YYYY-MM-DD') as last_maintenance_date,
        e.maintenance_frequency,
        e.maintenance_frequency_unit,
        e.notes,
        tu.full_name as assigned_user_name,
        b.name as branch_name
    FROM
        equipment e
    LEFT JOIN
        equipment_types et ON e.type_id = et.id
    LEFT JOIN
        equipment_brands eb ON e.brand_id = eb.id
    LEFT JOIN
        equipment_assignments ea ON e.id = ea.equipment_id AND ea.return_date IS NULL
    LEFT JOIN
        tenant_users tu ON ea.user_id = tu.user_id
    LEFT JOIN
        branches b ON ea.branch_id = b.id
    WHERE
        e.tenant_id = p_tenant_id
        AND (p_search_term IS NULL OR p_search_term = '' OR e.name ILIKE '%' || p_search_term || '%' OR e.serial_number ILIKE '%' || p_search_term || '%')
        AND (p_show_inactive OR e.is_active = TRUE)
        AND (p_type_id IS NULL OR e.type_id = p_type_id)
        AND (p_brand_id IS NULL OR e.brand_id = p_brand_id);
END;
$$;

-- Recreating create_product_transfer_request
DROP FUNCTION IF EXISTS "public"."create_product_transfer_request"("p_tenant_id" "uuid", "p_requesting_branch_id" "uuid", "p_origin_branch_id" "uuid", "p_notes" "text", "p_items" "jsonb");

CREATE OR REPLACE FUNCTION "public"."create_product_transfer_request"("p_tenant_id" "uuid", "p_requesting_branch_id" "uuid", "p_origin_branch_id" "uuid", "p_notes" "text", "p_items" "jsonb", "p_platform_id" "uuid" DEFAULT NULL::uuid) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    new_transfer record;
    item jsonb;
BEGIN
    -- 1. Create the product_transfers record
    INSERT INTO public.product_transfers (
        tenant_id,
        requesting_branch_id,
        origin_branch_id,
        destination_branch_id,
        status,
        notes,
        transfer_date
    )
    VALUES (
        p_tenant_id,
        p_requesting_branch_id,
        p_origin_branch_id,
        p_requesting_branch_id, -- Destination is the same as the requesting branch
        'solicitado',
        p_notes,
        now()
    )
    RETURNING * INTO new_transfer;

    -- 2. Create product_transfer_items records
    FOR item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        INSERT INTO public.product_transfer_items (
            transfer_id,
            product_id,
            quantity
        )
        VALUES (
            new_transfer.id,
            (item->>'product_id')::uuid,
            (item->>'quantity')::integer
        );
    END LOOP;

    -- 3. Return the newly created transfer
    RETURN to_jsonb(new_transfer);
END;
$$;

-- Recreating approve_product_transfer
DROP FUNCTION IF EXISTS "public"."approve_product_transfer"("p_transfer_id" "uuid", "p_adjusted_items" "jsonb", "p_tenant_id" "uuid", "p_user_id" "uuid");

CREATE OR REPLACE FUNCTION "public"."approve_product_transfer"("p_transfer_id" "uuid", "p_adjusted_items" "jsonb", "p_tenant_id" "uuid", "p_user_id" "uuid", "p_platform_id" "uuid" DEFAULT NULL::uuid) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_origin_branch_id uuid;
    item jsonb;
    v_product_id uuid;
    v_stock numeric;
    updated_transfer record;
    v_user_is_in_origin_branch boolean;
BEGIN
    -- 1. Check if the transfer exists and get its origin branch
    SELECT origin_branch_id INTO v_origin_branch_id
    FROM public.product_transfers
    WHERE id = p_transfer_id AND tenant_id = p_tenant_id AND status = 'solicitado';

    IF v_origin_branch_id IS NULL THEN
        RAISE EXCEPTION 'Transfer not found or not in "solicitado" state.';
    END IF;

    -- 2. Check if the user is assigned to the origin branch
    SELECT EXISTS (
        SELECT 1
        FROM auth.users u,
             jsonb_array_elements(u.raw_app_meta_data->'assignments') as assignment
        WHERE u.id = p_user_id
          AND assignment->>'branch_id' = v_origin_branch_id::text
          AND assignment->>'tenant_id' = p_tenant_id::text
    ) INTO v_user_is_in_origin_branch;

    IF NOT v_user_is_in_origin_branch THEN
        RAISE EXCEPTION 'You do not have permission to approve this transfer.';
    END IF;

    -- 3. Update quantities for each item and check stock
    FOR item IN SELECT * FROM jsonb_array_elements(p_adjusted_items)
    LOOP
        -- Get product_id for the item
        SELECT product_id INTO v_product_id
        FROM public.product_transfer_items
        WHERE id = (item->>'item_id')::uuid;

        -- Check available stock in the origin branch
        SELECT stock_quantity INTO v_stock
        FROM public.branch_products
        WHERE branch_id = v_origin_branch_id AND product_id = v_product_id;

        IF v_stock IS NULL OR v_stock < (item->>'quantity')::numeric THEN
            RAISE EXCEPTION 'Not enough stock for product ID % in origin branch.', v_product_id;
        END IF;

        -- Update the quantity in the transfer item
        UPDATE public.product_transfer_items
        SET quantity = (item->>'quantity')::integer, updated_at = now()
        WHERE id = (item->>'item_id')::uuid;
    END LOOP;

    -- 4. Update the transfer status to 'aprobado'
    UPDATE public.product_transfers
    SET status = 'aprobado', updated_at = now()
    WHERE id = p_transfer_id
    RETURNING * INTO updated_transfer;

    -- 5. Return the updated transfer
    RETURN to_jsonb(updated_transfer);
END;
$$;

-- Recreating reject_product_transfer
DROP FUNCTION IF EXISTS "public"."reject_product_transfer"("p_transfer_id" "uuid", "p_tenant_id" "uuid", "p_user_id" "uuid");

CREATE OR REPLACE FUNCTION "public"."reject_product_transfer"("p_transfer_id" "uuid", "p_tenant_id" "uuid", "p_user_id" "uuid", "p_platform_id" "uuid" DEFAULT NULL::uuid) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    updated_transfer record;
    v_origin_branch_id uuid;
    v_user_is_in_origin_branch boolean;
BEGIN
    -- 1. Check if the transfer exists and get its origin branch
    SELECT origin_branch_id INTO v_origin_branch_id
    FROM public.product_transfers
    WHERE id = p_transfer_id AND tenant_id = p_tenant_id AND status = 'solicitado';

    IF v_origin_branch_id IS NULL THEN
        RAISE EXCEPTION 'Transfer not found, not in "solicitado" state, or you do not have permission.';
    END IF;

    -- 2. Check if the user is assigned to the origin branch
    SELECT EXISTS (
        SELECT 1
        FROM auth.users u,
             jsonb_array_elements(u.raw_app_meta_data->'assignments') as assignment
        WHERE u.id = p_user_id
          AND assignment->>'branch_id' = v_origin_branch_id::text
          AND assignment->>'tenant_id' = p_tenant_id::text
    ) INTO v_user_is_in_origin_branch;

    IF NOT v_user_is_in_origin_branch THEN
        RAISE EXCEPTION 'You do not have permission to reject this transfer.';
    END IF;

    -- 3. Update the transfer status to 'rechazado'
    UPDATE public.product_transfers
    SET status = 'rechazado', updated_at = now()
    WHERE id = p_transfer_id
    RETURNING * INTO updated_transfer;

    RETURN to_jsonb(updated_transfer);
END;
$$;

-- Recreating ship_product_transfer
DROP FUNCTION IF EXISTS "public"."ship_product_transfer"("p_transfer_id" "uuid", "p_tenant_id" "uuid", "p_user_id" "uuid");

CREATE OR REPLACE FUNCTION "public"."ship_product_transfer"("p_transfer_id" "uuid", "p_tenant_id" "uuid", "p_user_id" "uuid", "p_platform_id" "uuid" DEFAULT NULL::uuid) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_transfer record;
    item record;
    v_user_is_in_origin_branch boolean;
BEGIN
    -- 1. Find the approved transfer for the current tenant
    SELECT * INTO v_transfer
    FROM public.product_transfers
    WHERE id = p_transfer_id AND tenant_id = p_tenant_id AND status = 'aprobado';

    IF v_transfer IS NULL THEN
        RAISE EXCEPTION 'Approved transfer not found.';
    END IF;

    -- 2. Check if the user is assigned to the origin branch
    SELECT EXISTS (
        SELECT 1
        FROM auth.users u,
             jsonb_array_elements(u.raw_app_meta_data->'assignments') as assignment
        WHERE u.id = p_user_id
          AND assignment->>'branch_id' = v_transfer.origin_branch_id::text
          AND assignment->>'tenant_id' = p_tenant_id::text
    ) INTO v_user_is_in_origin_branch;

    IF NOT v_user_is_in_origin_branch THEN
        RAISE EXCEPTION 'You do not have permission to ship this transfer.';
    END IF;

    -- 3. Deduct stock from the origin branch for each item in the transfer
    FOR item IN
        SELECT pti.product_id, pti.quantity
        FROM public.product_transfer_items pti
        WHERE pti.transfer_id = v_transfer.id
    LOOP
        UPDATE public.branch_products
        SET stock_quantity = stock_quantity - item.quantity
        WHERE branch_id = v_transfer.origin_branch_id AND product_id = item.product_id;
    END LOOP;

    -- 4. Update the transfer status to 'en_transito'
    UPDATE public.product_transfers
    SET status = 'en_transito', updated_at = now()
    WHERE id = p_transfer_id
    RETURNING * INTO v_transfer;

    -- 5. Return the updated transfer
    RETURN to_jsonb(v_transfer);
END;
$$;

-- Recreating cancel_product_transfer
DROP FUNCTION IF EXISTS "public"."cancel_product_transfer"("p_transfer_id" "uuid", "p_tenant_id" "uuid", "p_user_id" "uuid");

CREATE OR REPLACE FUNCTION "public"."cancel_product_transfer"("p_transfer_id" "uuid", "p_tenant_id" "uuid", "p_user_id" "uuid", "p_platform_id" "uuid" DEFAULT NULL::uuid) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    updated_transfer record;
    v_transfer_status text;
    v_origin_branch_id uuid;
    v_destination_branch_id uuid;
    v_user_can_cancel boolean;
BEGIN
    -- 1. Get transfer details
    SELECT status, origin_branch_id, destination_branch_id
    INTO v_transfer_status, v_origin_branch_id, v_destination_branch_id
    FROM public.product_transfers
    WHERE id = p_transfer_id AND tenant_id = p_tenant_id;

    IF v_transfer_status IS NULL THEN
        RAISE EXCEPTION 'Transfer not found or you do not have permission.';
    END IF;

    -- 2. Check permissions
    v_user_can_cancel := false;
    IF v_transfer_status = 'solicitado' THEN
        SELECT EXISTS (
            SELECT 1
            FROM auth.users u,
                 jsonb_array_elements(u.raw_app_meta_data->'assignments') as assignment
            WHERE u.id = p_user_id
              AND (assignment->>'branch_id' = v_origin_branch_id::text OR assignment->>'branch_id' = v_destination_branch_id::text)
              AND assignment->>'tenant_id' = p_tenant_id::text
        ) INTO v_user_can_cancel;
    ELSIF v_transfer_status = 'aprobado' THEN
        SELECT EXISTS (
            SELECT 1
            FROM auth.users u,
                 jsonb_array_elements(u.raw_app_meta_data->'assignments') as assignment
            WHERE u.id = p_user_id
              AND assignment->>'branch_id' = v_origin_branch_id::text
              AND assignment->>'tenant_id' = p_tenant_id::text
        ) INTO v_user_can_cancel;
    END IF;

    IF NOT v_user_can_cancel THEN
        RAISE EXCEPTION 'You do not have permission to cancel this transfer in its current state.';
    END IF;

    -- 3. Update the transfer status to 'cancelado'
    UPDATE public.product_transfers
    SET status = 'cancelado', updated_at = now()
    WHERE id = p_transfer_id
    RETURNING * INTO updated_transfer;

    RETURN to_jsonb(updated_transfer);
END;
$$;

-- Recreating get_transfer_details
DROP FUNCTION IF EXISTS "public"."get_transfer_details"("p_transfer_id" "uuid", "p_tenant_id" "uuid");

CREATE OR REPLACE FUNCTION "public"."get_transfer_details"("p_transfer_id" "uuid", "p_tenant_id" "uuid", "p_platform_id" "uuid" DEFAULT NULL::uuid) RETURNS TABLE("item_id" "uuid", "product_id" "uuid", "product_name" "text", "quantity" numeric, "allow_decimal_sale" boolean)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        pti.id as item_id,
        pti.product_id,
        p.name as product_name,
        pti.quantity,
        p.allow_decimal_sale -- Añadido el nuevo campo
    FROM
        public.product_transfer_items pti
    JOIN
        public.products p ON pti.product_id = p.id
    JOIN
        public.product_transfers pt ON pti.transfer_id = pt.id
    WHERE
        pti.transfer_id = p_transfer_id
        AND pt.tenant_id = p_tenant_id;
END;
$$;

