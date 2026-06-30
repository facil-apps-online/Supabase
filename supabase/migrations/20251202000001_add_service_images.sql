-- 1. Create the service_images table
CREATE TABLE public.service_images (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    service_id uuid NOT NULL,
    tenant_id uuid NOT NULL,
    google_drive_file_id text NOT NULL,
    image_url text, -- Can be derived, but storing it simplifies queries
    file_name text,
    file_size bigint,
    mime_type text,
    is_primary boolean NOT NULL DEFAULT false,
    sort_order integer NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT service_images_pkey PRIMARY KEY (id),
    CONSTRAINT fk_service_images_service FOREIGN KEY (service_id) REFERENCES public.services(id) ON DELETE CASCADE,
    CONSTRAINT fk_service_images_tenant FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE
);

COMMENT ON TABLE public.service_images IS 'Stores images associated with a service, similar to product_images.';
COMMENT ON COLUMN public.service_images.is_primary IS 'Indicates if this is the primary image for the service.';
COMMENT ON COLUMN public.service_images.sort_order IS 'Defines the display order of the images.';

-- 2. Add indexes
CREATE INDEX idx_service_images_service_id ON public.service_images(service_id);
CREATE UNIQUE INDEX unique_primary_image_per_service ON public.service_images (service_id) WHERE (is_primary);

-- 3. Enable RLS and define policies
ALTER TABLE public.service_images ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Allow tenant members to manage service images"
ON public.service_images
FOR ALL
USING (
    EXISTS (
        SELECT 1
        FROM public.user_assignments ua
        WHERE ua.tenant_id = service_images.tenant_id
          AND ua.user_id = auth.uid()
    )
)
WITH CHECK (
    EXISTS (
        SELECT 1
        FROM public.user_assignments ua
        WHERE ua.tenant_id = service_images.tenant_id
          AND ua.user_id = auth.uid()
    )
);

-- 4. Add triggers
CREATE TRIGGER handle_updated_at BEFORE UPDATE ON public.service_images
FOR EACH ROW EXECUTE PROCEDURE moddatetime (updated_at);

-- 5. Update the handle_google_drive_file_delete function and re-create triggers
DROP FUNCTION IF EXISTS public.handle_google_drive_file_delete() CASCADE;

CREATE FUNCTION public.handle_google_drive_file_delete()
RETURNS TRIGGER AS $$
DECLARE
  v_file_id TEXT;
  v_tenant_id UUID;
  v_jwt TEXT;
BEGIN
  BEGIN
    v_jwt := current_setting('request.jwt.claim', true);
  EXCEPTION
    WHEN OTHERS THEN
      v_jwt := NULL;
  END;

  IF TG_TABLE_NAME = 'attention_service_evidences'
     OR TG_TABLE_NAME = 'attention_payment_evidences'
     OR TG_TABLE_NAME = 'product_images'
     OR TG_TABLE_NAME = 'service_images' THEN -- Added service_images
    v_file_id := OLD.google_drive_file_id;
    v_tenant_id := OLD.tenant_id;
  END IF;

  IF v_file_id IS NULL THEN
    RETURN OLD;
  END IF;

  PERFORM net.http_post(
    url := 'https://zvzmnqcbmhpddrpfjrzr.supabase.co/functions/v1/google-drive-delete',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_jwt
    ),
    body := jsonb_build_object(
      'fileId', v_file_id,
      'tenantId', v_tenant_id
    )
  );

  RETURN OLD;
END;
$$ LANGUAGE plpgsql;

-- Re-create all triggers that use this function
CREATE TRIGGER on_service_evidence_deleted
AFTER DELETE ON public.attention_service_evidences
FOR EACH ROW
EXECUTE FUNCTION public.handle_google_drive_file_delete();

CREATE TRIGGER on_payment_evidence_deleted
AFTER DELETE ON public.attention_payment_evidences
FOR EACH ROW
EXECUTE FUNCTION public.handle_google_drive_file_delete();

CREATE TRIGGER on_product_image_deleted
AFTER DELETE ON public.product_images
FOR EACH ROW
EXECUTE FUNCTION public.handle_google_drive_file_delete();

-- Add the new trigger for service_images
CREATE TRIGGER on_service_image_deleted
AFTER DELETE ON public.service_images
FOR EACH ROW
EXECUTE FUNCTION public.handle_google_drive_file_delete();

-- 6. Update storage usage function
create or replace function get_tenant_storage_usage_by_table(p_tenant_id uuid)
returns table(table_name text, "size" bigint) as $$
begin
  return query
    select 'product_images' as table_name, coalesce(sum(file_size), 0)::bigint as "size" from product_images where tenant_id = p_tenant_id
    union all
    select 'service_images' as table_name, coalesce(sum(file_size), 0)::bigint as "size" from service_images where tenant_id = p_tenant_id
    union all
    select 'attention_service_evidences' as table_name, coalesce(sum(file_size), 0)::bigint as "size" from attention_service_evidences where tenant_id = p_tenant_id
    union all
    select 'attention_payment_evidences' as table_name, coalesce(sum(file_size), 0)::bigint as "size" from attention_payment_evidences where tenant_id = p_tenant_id
    union all
    select 'commission_payment_evidences' as table_name, coalesce(sum(file_size), 0)::bigint as "size" from commission_payment_evidences where tenant_id = p_tenant_id
    union all
    select 'consent_signatures' as table_name, coalesce(sum(file_size), 0)::bigint as "size" from consent_signatures where tenant_id = p_tenant_id;
end;
$$ language plpgsql;
