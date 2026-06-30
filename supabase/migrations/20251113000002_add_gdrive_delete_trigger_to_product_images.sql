-- Drop the function and its dependent triggers
DROP FUNCTION IF EXISTS public.handle_google_drive_file_delete() CASCADE;

-- Re-create the function with the updated logic (including product_images)
CREATE FUNCTION public.handle_google_drive_file_delete()
RETURNS TRIGGER AS $$
DECLARE
  v_file_id TEXT;
  v_tenant_id UUID;
  v_jwt TEXT;
BEGIN
  -- Use a block to handle potential exceptions when getting the claim, e.g. during migrations
  BEGIN
    v_jwt := current_setting('request.jwt.claim', true);
  EXCEPTION
    WHEN OTHERS THEN
      v_jwt := NULL;
  END;

  -- Check which table the trigger is for and get the correct columns
  IF TG_TABLE_NAME = 'attention_service_evidences' 
     OR TG_TABLE_NAME = 'attention_payment_evidences' 
     OR TG_TABLE_NAME = 'product_images' THEN
    v_file_id := OLD.google_drive_file_id;
    v_tenant_id := OLD.tenant_id;
  END IF;

  -- If there's no file ID, there's nothing to do
  IF v_file_id IS NULL THEN
    RETURN OLD;
  END IF;

  -- Asynchronously invoke the edge function to delete the file
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

-- Trigger for service evidences
CREATE TRIGGER on_service_evidence_deleted
AFTER DELETE ON public.attention_service_evidences
FOR EACH ROW
EXECUTE FUNCTION public.handle_google_drive_file_delete();

-- Trigger for payment evidences
CREATE TRIGGER on_payment_evidence_deleted
AFTER DELETE ON public.attention_payment_evidences
FOR EACH ROW
EXECUTE FUNCTION public.handle_google_drive_file_delete();

-- Trigger for product images
CREATE TRIGGER on_product_image_deleted
AFTER DELETE ON public.product_images
FOR EACH ROW
EXECUTE FUNCTION public.handle_google_drive_file_delete();
