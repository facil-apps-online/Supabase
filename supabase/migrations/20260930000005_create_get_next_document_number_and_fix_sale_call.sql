-- get_next_document_number no existia en la BD (la migracion 20260712000020 la dropeaba y no llego a crearla) y
-- process_sale_from_attention la llamaba con la firma vieja (sin p_platform_id). Se crea y se corrige la llamada.
CREATE OR REPLACE FUNCTION public.get_next_document_number(p_tenant_id uuid, p_platform_id uuid, p_document_type text, p_branch_id uuid DEFAULT NULL::uuid, p_context_data jsonb DEFAULT '{}'::jsonb)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    sequence_rec RECORD;
    branch_rec RECORD;
    formatted_number text;
    next_number integer;
    current_ts timestamptz := now();
BEGIN
    SELECT * INTO sequence_rec
    FROM public.document_sequences
    WHERE tenant_id = p_tenant_id AND platform_id = p_platform_id
      AND document_type = p_document_type
      AND (branch_id = p_branch_id OR branch_id IS NULL)
      AND is_active = true
    ORDER BY branch_id DESC NULLS LAST
    LIMIT 1
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No active document sequence found for document type %', p_document_type;
    END IF;

    next_number := sequence_rec.current_number;
    UPDATE public.document_sequences SET current_number = current_number + 1 WHERE id = sequence_rec.id;

    formatted_number := COALESCE(sequence_rec.format_template, '{prefix}{sequence}');
    formatted_number := replace(formatted_number, '{YYYY}', to_char(current_ts, 'YYYY'));
    formatted_number := replace(formatted_number, '{YY}', to_char(current_ts, 'YY'));
    formatted_number := replace(formatted_number, '{MM}', to_char(current_ts, 'MM'));
    formatted_number := replace(formatted_number, '{DD}', to_char(current_ts, 'DD'));
    formatted_number := replace(formatted_number, '{prefix}', COALESCE(sequence_rec.prefix, ''));
    formatted_number := replace(formatted_number, '{sequence}', LPAD(next_number::text, sequence_rec.padding, '0'));

    IF p_branch_id IS NOT NULL THEN
        SELECT code INTO branch_rec FROM public.branches WHERE id = p_branch_id;
        IF FOUND THEN
            formatted_number := replace(formatted_number, '{branch_code}', COALESCE(branch_rec.code, ''));
        END IF;
    END IF;

    IF p_context_data ? 'direction' THEN
        formatted_number := replace(formatted_number, '{direction}', p_context_data->>'direction');
    END IF;

    RETURN formatted_number;
END;
$$;

DO $$
DECLARE
  v_def text;
BEGIN
  v_def := pg_get_functiondef('public.process_sale_from_attention(uuid,uuid,uuid)'::regprocedure);
  v_def := replace(v_def, 'get_next_document_number(p_tenant_id, ''SALE''::text,', 'get_next_document_number(p_tenant_id, p_platform_id, ''SALE''::text,');
  EXECUTE v_def;
END
$$;
